# Maps a raw pb.recv frame into a clip in the current stack.
#
# Registered as xs.actor.clipboard.create, same shape as the 2048 snapshot
# actor: the script itself is the frame body. Re-registering replaces the
# running actor. Editing this source from the panel comes later.
#
# .append inside an actor is buffered and does not return the new frame id,
# so a brand-new stack is written over the store socket. The response is the
# frame xs just stored, and its id is the stack id the clip points at.

def sock-path [] {
  let custom = $env.STACKS2_SOCK? | default ""
  if ($custom | is-empty) {
    "~/Library/Application Support/Stacks2/store/sock" | path expand
  } else {
    $custom
  }
}

def now-ms [] {
  ((date now | into int) / 1000000)
}

def stack-name [] {
  date now | format date "%a, %b %d %Y, %I:%M %p"
}

def is-link [text: string] {
  $text =~ '^https://[^\s/$.?#].[^\s]*$'
}

def fold-all [] {
  let frames = .cat | collect
  if ($frames | is-empty) {
    {stacks: [], deleted: []}
  } else {
    $frames | reduce --fold {stacks: [], deleted: []} {|frame, state|
      apply-frame $state $frame
    }
  }
}

def apply-frame [state: record, frame: record] {
  let meta = $frame.meta? | default {}
  match $frame.topic {
    "stack.add" => {
      $state | upsert stacks ($state.stacks | append {
        id: $frame.id
        locked: ($meta.locked? | default false)
        last: $frame.id
        clips: []
      })
    }
    "stack.update" => (update-stack $state $frame $meta)
    "stack.delete" => (delete-stack $state $frame $meta)
    "stack.restore" => (restore-stack $state $meta)
    "clip.add" => (add-clip $state $frame $meta)
    "clip.update" => (update-clip $state $frame $meta)
    "clip.patch" => (patch-clip $state $frame $meta)
    "clip.delete" => (delete-clip $state $frame $meta)
    "clip.restore" => (restore-clip $state $meta)
    _ => $state
  }
}

def update-stack [state: record, frame: record, meta: record] {
  let id = $meta.id? | default ""
  let bump = ($meta.name? != null) or (($meta.touch? | default false) == true)
  let stacks = $state.stacks | each {|s|
    if $s.id != $id {
      $s
    } else {
      let locked = if ($meta.locked? != null) { $meta.locked } else { $s.locked }
      let last = if $bump { $frame.id } else { $s.last }
      $s | upsert locked $locked | upsert last $last
    }
  }
  $state | upsert stacks $stacks
}

def delete-stack [state: record, frame: record, meta: record] {
  let id = $meta.id? | default ""
  let victim = $state.stacks | where id == $id | get 0?
  if $victim == null { return $state }
  $state
  | upsert stacks ($state.stacks | where id != $id)
  | upsert deleted ([{frame_id: $frame.id, kind: "stack", stack: $victim}] | append $state.deleted)
}

def restore-stack [state: record, meta: record] {
  let target = $meta.target? | default ""
  let entry = $state.deleted | where {|d| $d.frame_id == $target and $d.kind == "stack"} | get 0?
  if $entry == null { return $state }
  $state
  | upsert stacks ($state.stacks | append $entry.stack)
  | upsert deleted ($state.deleted | where frame_id != $target)
}

def add-clip [state: record, frame: record, meta: record] {
  let sid = $meta.stack_id? | default ""
  let clip = {id: $frame.id, hash: ($frame.hash? | default "")}
  let stacks = $state.stacks | each {|s|
    if $s.id != $sid {
      $s
    } else {
      $s | upsert clips ($s.clips | append $clip) | upsert last $frame.id
    }
  }
  $state | upsert stacks $stacks
}

def update-clip [state: record, frame: record, meta: record] {
  let id = $meta.id? | default ""
  let hash = $frame.hash? | default ""
  let stacks = $state.stacks | each {|s|
    let hit = $s.clips | any {|c| $c.id == $id}
    if not $hit {
      $s
    } else {
      let clips = $s.clips | each {|c| if $c.id == $id { $c | upsert hash $hash } else { $c } }
      $s | upsert clips $clips | upsert last $frame.id
    }
  }
  $state | upsert stacks $stacks
}

def patch-clip [state: record, frame: record, meta: record] {
  let id = $meta.id? | default ""
  let dest = $meta.stack_id? | default ""
  let touch = (($meta.touch? | default false) == true)
  let owner = $state.stacks | where {|s| $s.clips | any {|c| $c.id == $id}} | get 0?
  if $owner == null { return $state }
  let clip = $owner.clips | where id == $id | get 0
  let target = if ($dest | is-empty) { $owner.id } else { $dest }
  let removed = $state.stacks | each {|s|
    if $s.id == $owner.id {
      $s | upsert clips ($s.clips | where id != $id)
    } else {
      $s
    }
  }
  let placed = $removed | each {|s|
    if $s.id != $target {
      $s
    } else {
      let last = if $touch { $frame.id } else { $s.last }
      $s | upsert clips ($s.clips | append $clip) | upsert last $last
    }
  }
  let stacks = if $touch and $target != $owner.id {
    $placed | each {|s| if $s.id == $owner.id { $s | upsert last $frame.id } else { $s }}
  } else {
    $placed
  }
  $state | upsert stacks $stacks
}

def delete-clip [state: record, frame: record, meta: record] {
  let id = $meta.id? | default ""
  let owner = $state.stacks | where {|s| $s.clips | any {|c| $c.id == $id}} | get 0?
  if $owner == null { return $state }
  let clip = $owner.clips | where id == $id | get 0
  let stacks = $state.stacks | each {|s|
    if $s.id != $owner.id {
      $s
    } else {
      $s | upsert clips ($s.clips | where id != $id) | upsert last $frame.id
    }
  }
  let deleted = [{frame_id: $frame.id, kind: "clip", clip: $clip, stack_id: $owner.id}] | append $state.deleted
  $state | upsert stacks $stacks | upsert deleted $deleted
}

def restore-clip [state: record, meta: record] {
  let target = $meta.target? | default ""
  let entry = $state.deleted | where {|d| $d.frame_id == $target and $d.kind == "clip"} | get 0?
  if $entry == null { return $state }
  let stacks = $state.stacks | each {|s|
    if $s.id != $entry.stack_id {
      $s
    } else {
      $s | upsert clips ($s.clips | append $entry.clip)
    }
  }
  $state
  | upsert stacks $stacks
  | upsert deleted ($state.deleted | where frame_id != $target)
}

def pick-stack [state: record] {
  if ($state.stacks | is-empty) { return null }
  let open = $state.stacks | sort-by last | reverse | where locked == false | get 0?
  if $open == null { return null }
  let ts = ($open.last | .id unpack | get ts_ms)
  if ((now-ms) - $ts) < 3600000 { $open.id } else { null }
}

# An ephemeral stack (for a concealed clip, when no stack is open) is never
# stored, so it doesn't outlive the clip as an empty stack.
def make-stack [name: string, --ephemeral] {
  let meta = {name: $name, sort: "auto", layout: "flow"} | to json -r
  let b64 = $meta | encode base64 | str replace -a "\n" "" | str replace -a "\r" ""
  let query = if $ephemeral { "?ttl=ephemeral" } else { "" }
  let raw = (
    "" | ^/usr/bin/curl -sS -f --max-time 5 --unix-socket (sock-path)
      -X POST
      -H $"xs-meta: ($b64)"
      --data-binary @-
      $"http://localhost/append/stack.add($query)"
  )
  $raw | from json | get id
}

def tiff-to-png [bytes: binary] {
  let src = "/tmp/stacks2-clip.tiff"
  let dst = "/tmp/stacks2-clip.png"
  $bytes | save --force $src
  ^/usr/bin/sips -s format png $src --out $dst | ignore
  let png = open --raw $dst
  rm $src
  rm $dst
  $png
}

# A concealed copy (a password) arrives as an ephemeral pb.recv with its
# record in meta, and becomes an ephemeral clip with its content in meta: no
# content goes into the CAS and nothing is stored. The panel drops it after a
# while. A TIFF is skipped, since converting it writes temp files.
def handle-concealed [frame: record] {
  let types = $frame.meta.record?.types? | default {}
  let png = $types."public.png"? | default ""
  let text64 = $types."public.utf8-plain-text"? | default ""
  let content = if not ($png | is-empty) {
    {mime_type: "image/png", content_type: "Image", image: $"data:image/png;base64,($png)"}
  } else if not ($text64 | is-empty) {
    let text = $text64 | decode base64 | decode utf-8
    if ($text | str trim | is-empty) { null } else { {mime_type: "text/plain", content_type: "Text", text: $text} }
  } else {
    null
  }
  if $content == null { return }
  let picked = pick-stack (fold-all)
  let stack_id = if $picked == null { make-stack (stack-name) --ephemeral } else { $picked }
  null | .append clip.add --ttl ephemeral --meta ({
    stack_id: $stack_id
    kind: "content"
    concealed: true
    source: $frame.id
  } | merge $content)
}

def handle [frame: record] {
  if ($frame.meta?.concealed? | default false) == true {
    handle-concealed $frame
    return
  }
  let raw = (.cas $frame.hash | from json)
  let types = $raw.types? | default {}
  let png = $types."public.png"? | default ""
  let tiff = $types."public.tiff"? | default ""
  let text64 = $types."public.utf8-plain-text"? | default ""

  let mapped = if not ($png | is-empty) {
    {bytes: ($png | decode base64), mime: "image/png", content_type: "Image"}
  } else if not ($tiff | is-empty) {
    {bytes: (tiff-to-png ($tiff | decode base64)), mime: "image/png", content_type: "Image"}
  } else if not ($text64 | is-empty) {
    let text = $text64 | decode base64 | decode utf-8
    if ($text | str trim | is-empty) {
      null
    } else {
      let content_type = if (is-link $text) { "Link" } else { "Text" }
      {bytes: $text, mime: "text/plain", content_type: $content_type}
    }
  } else {
    null
  }

  if $mapped == null { return }

  let hash = $mapped.bytes | .cas-post
  let folded = fold-all
  let picked = pick-stack $folded
  let stack_id = if $picked == null { make-stack (stack-name) } else { $picked }
  let stack = $folded.stacks | where id == $stack_id | get 0?
  let existing = if $stack == null {
    null
  } else {
    $stack.clips | where hash == $hash | get 0?
  }

  if $existing != null {
    null | .append clip.patch --meta {id: $existing.id, touch: true}
    return
  }

  $mapped.bytes | .append clip.add --meta {
    stack_id: $stack_id
    kind: "content"
    mime_type: $mapped.mime
    content_type: $mapped.content_type
    source: $frame.id
  }
}

{
  run: {|frame, state = null|
    if $frame.topic != "pb.recv" {
      return {next: $state}
    }
    try {
      handle $frame
    } catch {|err|
      print $"clipboard: ($err.msg)"
    }
    {next: $state}
  }
  start: "new"
  topics: ["pb.recv"]
}
