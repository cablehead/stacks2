# Maps a raw pb.recv frame into a clip.
#
# Registered as xs.actor.clipboard.create, same shape as the 2048 snapshot
# actor: the script itself is the frame body. Re-registering replaces the
# running actor. Editing this source from the panel comes later.
#
# The actor only maps: each copy becomes a clip.add with no stack. It keeps no
# state and reads nothing back. Which stack a clip lands on, and whether it
# repeats a clip already there, is decided by the panel as it folds every
# frame (panel.html, placeClip), from the frames' own times.

def is-link [text: string] {
  $text =~ '^https://[^\s/$.?#].[^\s]*$'
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
  null | .append clip.add --ttl ephemeral --meta ({
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

  $mapped.bytes | .append clip.add --meta {
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
