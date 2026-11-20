//! xs, built into Stacks2.
//!
//! A C interface over the cross-stream store, so Stacks2 opens its store in
//! its own process and calls it directly. What `xs serve` runs besides the
//! store runs here too: the actor, service and action processors, and the
//! socket server, which the `xs` command (and anything else outside Stacks2)
//! still reaches the store through.
//!
//! Strings in and out are UTF-8 and NUL-terminated. Every `char *` this
//! returns is freed with `xs_free_string`, and every byte buffer with
//! `xs_free_bytes`. Results are JSON shaped as the xs HTTP API shapes them,
//! and a failure is `{"error": "..."}`.

// Every pointer here comes from Stacks2's Swift side, which owns the contract
// in the doc comment above. Marking the C functions `unsafe` would change
// nothing for their caller, so the lint is allowed for the crate.
#![allow(clippy::not_unsafe_ptr_arg_deref)]

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

use tokio::runtime::Runtime;
use tokio::sync::oneshot;
use xs::{Frame, ReadOptions, Store, StoreError, StoreOptions, TTL};

struct Open {
    runtime: Runtime,
    store: Store,
    service: Mutex<Option<tokio::task::JoinHandle<()>>>,
}

static OPEN: OnceLock<Open> = OnceLock::new();
static FOLLOWS: OnceLock<Mutex<HashMap<u64, oneshot::Sender<()>>>> = OnceLock::new();
static NEXT_FOLLOW: AtomicU64 = AtomicU64::new(1);

fn follows() -> &'static Mutex<HashMap<u64, oneshot::Sender<()>>> {
    FOLLOWS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn text(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

fn out(s: String) -> *mut c_char {
    CString::new(s.replace('\0', ""))
        .map(CString::into_raw)
        .unwrap_or(std::ptr::null_mut())
}

fn error(message: impl std::fmt::Display) -> String {
    serde_json::json!({ "error": message.to_string() }).to_string()
}

fn query(s: &str) -> Option<&str> {
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

/// Opens the store at `path` and starts xs's processors and socket server.
/// Returns NULL once open, or an error message (free it). Opening twice is an
/// error: there is one store per process.
#[no_mangle]
pub extern "C" fn xs_open(path: *const c_char) -> *mut c_char {
    if OPEN.get().is_some() {
        return out("the store is already open".into());
    }
    let path = PathBuf::from(text(path));
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .thread_name("xs")
        .build()
    {
        Ok(rt) => rt,
        Err(e) => return out(format!("could not start xs: {e}")),
    };
    // The store keeps the runtime it was opened in, for its live reads.
    let _inside = runtime.enter();
    let store = match Store::open(path.clone(), StoreOptions::default()) {
        Ok(store) => store,
        Err(StoreError::Locked) => {
            return out(format!(
                "the store at {} is in use by another xs; stop it and start Stacks2 again",
                path.display()
            ))
        }
        Err(e) => return out(format!("could not open the store: {e}")),
    };
    let engine = match runtime.block_on(async { xs::nu::Engine::new() }) {
        Ok(engine) => engine,
        Err(e) => return out(format!("could not start xs's Nushell engine: {e}")),
    };

    // The task handle is returned on purpose, to be kept, not awaited here.
    #[allow(clippy::async_yields_async)]
    let service = runtime.block_on(async {
        for (name, run) in [
            ("actor", tokio::spawn(xs::processor::actor::run(store.clone()))),
            ("action", tokio::spawn(xs::processor::action::run(store.clone()))),
        ] {
            tokio::spawn(async move {
                if let Ok(Err(e)) = run.await {
                    eprintln!("xs {name} processor: {e}");
                }
            });
        }
        let s = store.clone();
        let service = tokio::spawn(async move {
            if let Err(e) = xs::processor::service::run(s).await {
                eprintln!("xs service processor: {e}");
            }
        });
        let (s, e) = (store.clone(), engine.clone());
        tokio::spawn(async move {
            if let Err(err) = xs::api::serve(s, e, None).await {
                eprintln!("xs socket server: {err}");
            }
        });
        service
    });

    let _ = OPEN.set(Open {
        runtime,
        store,
        service: Mutex::new(Some(service)),
    });
    std::ptr::null_mut()
}

fn open() -> Result<&'static Open, String> {
    OPEN.get().ok_or_else(|| "the store isn't open".to_string())
}

/// Appends a frame to `topic`. `body` (may be empty) goes into the CAS and
/// the frame points at it. `meta_json` is a JSON object or empty. `query` is
/// as the HTTP append takes it, for a TTL: `ttl=last:1`. Returns the frame.
#[no_mangle]
pub extern "C" fn xs_append(
    topic: *const c_char,
    query_s: *const c_char,
    meta_json: *const c_char,
    body: *const u8,
    len: usize,
) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let o = open()?;
        let topic = text(topic);
        let q = text(query_s);
        let ttl = TTL::from_query(query(&q))?;
        let meta = text(meta_json);
        let meta: Option<serde_json::Value> = if meta.trim().is_empty() {
            None
        } else {
            Some(serde_json::from_str(&meta).map_err(|e| format!("meta isn't valid JSON: {e}"))?)
        };
        let hash = if len == 0 || body.is_null() {
            None
        } else {
            let bytes = unsafe { std::slice::from_raw_parts(body, len) };
            Some(o.store.cas_insert_bytes_sync(bytes).map_err(|e| e.to_string())?)
        };
        let frame = o
            .store
            .append(
                Frame::builder(topic)
                    .maybe_hash(hash)
                    .maybe_meta(meta)
                    .ttl(ttl)
                    .build(),
            )
            .map_err(|e| e.to_string())?;
        serde_json::to_string(&frame).map_err(|e| e.to_string())
    })();
    out(result.unwrap_or_else(error))
}

/// Reads frames as a JSON array, without following. `query` is as the HTTP
/// read takes it (`topic=clip.*&last=10`), or empty for every frame.
#[no_mangle]
pub extern "C" fn xs_read(query_s: *const c_char) -> *mut c_char {
    let result = (|| -> Result<String, String> {
        let o = open()?;
        let q = text(query_s);
        let options = ReadOptions::from_query(query(&q)).map_err(|e| e.to_string())?;
        let frames: Vec<Frame> = o.store.read_sync(options).collect();
        serde_json::to_string(&frames).map_err(|e| e.to_string())
    })();
    out(result.unwrap_or_else(error))
}

/// Reads the CAS content for `hash`. Returns the bytes and sets `len`, or
/// returns NULL and sets `err` (free it).
#[no_mangle]
pub extern "C" fn xs_cas(hash: *const c_char, len: *mut usize, err: *mut *mut c_char) -> *mut u8 {
    let result = (|| -> Result<Vec<u8>, String> {
        let o = open()?;
        let hash: ssri::Integrity = text(hash)
            .parse()
            .map_err(|e| format!("invalid CAS hash: {e}"))?;
        o.store.cas_read_sync(&hash).map_err(|e| e.to_string())
    })();
    match result {
        Ok(bytes) => {
            let boxed = bytes.into_boxed_slice();
            unsafe { *len = boxed.len() };
            Box::into_raw(boxed) as *mut u8
        }
        Err(e) => {
            unsafe {
                *len = 0;
                if !err.is_null() {
                    *err = out(e);
                }
            }
            std::ptr::null_mut()
        }
    }
}

/// Called with each frame as one line of JSON, from an xs thread. Called a
/// last time with NULL when the follow ends, however it ends: the `ctx` can
/// be released then, and not before.
pub type XsLine = extern "C" fn(ctx: *mut c_void, json: *const c_char);

struct Ctx(*mut c_void);
unsafe impl Send for Ctx {}

/// Reads frames as `xs_read` does, then follows new ones: `follow=true` is
/// added to `query`. Returns an id for `xs_follow_stop`, or 0 when the store
/// isn't open (`line` then gets only the closing NULL).
#[no_mangle]
pub extern "C" fn xs_follow(query_s: *const c_char, line: XsLine, ctx: *mut c_void) -> u64 {
    let ctx = Ctx(ctx);
    let o = match open() {
        Ok(o) => o,
        Err(_) => {
            line(ctx.0, std::ptr::null());
            return 0;
        }
    };
    let q = text(query_s);
    let q = if q.is_empty() { "follow=true".to_string() } else { format!("{q}&follow=true") };
    let options = match ReadOptions::from_query(Some(&q)) {
        Ok(options) => options,
        Err(e) => {
            eprintln!("xs follow: {e}");
            line(ctx.0, std::ptr::null());
            return 0;
        }
    };
    let id = NEXT_FOLLOW.fetch_add(1, Ordering::Relaxed);
    let (stop, mut stopped) = oneshot::channel();
    follows().lock().unwrap().insert(id, stop);
    let store = o.store.clone();
    o.runtime.spawn(async move {
        let ctx = ctx;
        let mut rx = store.read(options);
        loop {
            tokio::select! {
                _ = &mut stopped => break,
                item = rx.recv() => match item {
                    Some(Ok(frame)) => {
                        if let Ok(json) = serde_json::to_string(&frame) {
                            if let Ok(c) = CString::new(json) {
                                line(ctx.0, c.as_ptr());
                            }
                        }
                    }
                    Some(Err(e)) => {
                        eprintln!("xs follow ended: {e:?}");
                        break;
                    }
                    None => break,
                },
            }
        }
        follows().lock().unwrap().remove(&id);
        line(ctx.0, std::ptr::null());
    });
    id
}

/// Ends a follow. Its callback gets its closing NULL soon after.
#[no_mangle]
pub extern "C" fn xs_follow_stop(id: u64) {
    if let Some(stop) = follows().lock().unwrap().remove(&id) {
        let _ = stop.send(());
    }
}

/// Stops xs as `xs serve` does on SIGTERM: appends `xs.stopping`, gives
/// services up to 3 seconds to wind down, and flushes the store.
#[no_mangle]
pub extern "C" fn xs_close() {
    let Ok(o) = open() else { return };
    let _ = o.store.append(Frame::builder("xs.stopping").build());
    if let Some(service) = o.service.lock().unwrap().take() {
        let _ = o
            .runtime
            .block_on(async { tokio::time::timeout(Duration::from_secs(3), service).await });
    }
    let _ = o.store.flush();
}

#[no_mangle]
pub extern "C" fn xs_free_string(s: *mut c_char) {
    if !s.is_null() {
        drop(unsafe { CString::from_raw(s) });
    }
}

#[no_mangle]
pub extern "C" fn xs_free_bytes(ptr: *mut u8, len: usize) {
    if !ptr.is_null() {
        drop(unsafe { Box::from_raw(std::ptr::slice_from_raw_parts_mut(ptr, len)) });
    }
}
