# Reads the text in each image clip, once per image.
#
# Registered as xs.actor.ocr.create: the script itself is the frame body.
# For each clip.add frame whose meta.mime_type is an image, the image bytes
# (the frame's CAS content) are piped through ~/bin/ocr --json, and the
# result is appended to a topic named after the content hash:
#
#   clip hash   sha256-mOpuTyFvL7S2n/+bOkSELDhobKaF8/VdxIxdP7EQe+Q=
#   ocr topic   ocr.sha256-mOpuTyFvL7S2n_-bOkSELDhobKaF8_VdxIxdP7EQe-Q
#
# A topic allows only a-z A-Z 0-9 _ - . so the hash's base64 is written as
# base64url: + becomes -, / becomes _, and the = padding is dropped. The
# exact hash is also in meta.hash.
#
# A hash is done once its topic has any frame. The same image clipped
# again, or the same frames replayed after a restart, is not read again.
# A failed read is recorded on the same topic with meta.error, so a bad
# image is not retried on every replay. Remove that frame to retry it.
#
# Each result frame:
#   content  JSON {text, lines}: text is the lines joined with newlines,
#            lines is ocr's own output, [{text, confidence, box}]
#   meta     {hash, mime_type, lines, chars, ms}, or {hash, mime_type,
#            error, ms} on failure. xs adds frame_id (the clip.add frame
#            that was read) and actor_id.
#
# start: "first", so image clips from before this actor existed, or from
# while it was stopped, are caught up on. On a replay each image clip
# costs one topic lookup.
#
# Register (xs is ~/git/stacks2/.bin/xs):
#   xs append "$HOME/Library/Application Support/Stacks2/store/sock" xs.actor.ocr.create < actors/ocr.nu
# Unregister:
#   xs append "$HOME/Library/Application Support/Stacks2/store/sock" xs.actor.ocr.term < /dev/null

def ocr-bin [] {
  "~/bin/ocr" | path expand
}

def ocr-topic [hash: string] {
  let safe = $hash | str replace -a "+" "-" | str replace -a "/" "_" | str replace -a "=" ""
  $"ocr.($safe)"
}

def is-image [mime: string] {
  ($mime | str starts-with "image/") and ($mime != "image/svg+xml")
}

def elapsed-ms [since: datetime] {
  (((date now) - $since) | into int) // 1000000
}

def handle [frame: record] {
  let meta = $frame.meta? | default {}
  let mime = $meta.mime_type? | default ""
  let hash = $frame.hash? | default ""
  if not (is-image $mime) or ($hash | is-empty) { return }

  let topic = ocr-topic $hash
  if (.last $topic) != null { return }

  let began = date now
  let result = try {
    # .cas is piped straight on: it is typed as returning a string, so
    # binding an image's bytes with let fails with a type mismatch.
    # perl's alarm ends ocr if it hangs; the timer survives the exec.
    let run = .cas $hash | ^/usr/bin/perl -e 'alarm shift; exec @ARGV or die' 60 (ocr-bin) --json - | complete
    if $run.exit_code != 0 {
      let why = $run.stderr | str trim
      {error: (if ($why | is-empty) { $"ocr exited ($run.exit_code)" } else { $why })}
    } else {
      {lines: ($run.stdout | from json)}
    }
  } catch {|err|
    {error: $err.msg}
  }
  let ms = elapsed-ms $began

  if ($result.error? != null) {
    null | .append $topic --meta {hash: $hash, mime_type: $mime, error: $result.error, ms: $ms}
    return
  }

  let lines = $result.lines
  let text = $lines | each {|l| $l.text } | str join "\n"
  {text: $text, lines: $lines} | to json -r | .append $topic --meta {
    hash: $hash
    mime_type: $mime
    lines: ($lines | length)
    chars: ($text | str length)
    ms: $ms
  }
}

{
  run: {|frame, state = null|
    if $frame.topic != "clip.add" {
      return {next: $state}
    }
    try {
      handle $frame
    } catch {|err|
      print $"ocr: ($err.msg)"
    }
    {next: $state}
  }
  start: "first"
  topics: ["clip.add"]
}
