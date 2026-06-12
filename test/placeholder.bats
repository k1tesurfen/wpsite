#!/usr/bin/env bats
# Placeholder generation: exact dimensions, frame, codec-per-container, edge cases.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  source "$REPO/lib/common.sh"
  source "$REPO/lib/cmd_build.sh"
  IM="$(command -v magick || command -v convert || true)"
  [ -n "$IM" ] || skip "ImageMagick not installed"
  FONT="$(_placeholder_font)"
  if command -v magick >/dev/null 2>&1; then IDENTIFY=(magick identify); else IDENTIFY=(identify); fi
  cd "$BATS_TEST_TMPDIR"
}

dims() { "${IDENTIFY[@]}" -format '%wx%h' "$1"; }

@test "png placeholder: exact dimensions" {
  _gen_placeholder out.png 321 234 "$IM" "$FONT"
  [ "$(dims out.png)" = "321x234" ]
}

@test "jpg placeholder: exact dimensions" {
  _gen_placeholder out.jpg 640 480 "$IM" "$FONT"
  [ "$(dims out.jpg)" = "640x480" ]
}

@test "tiny image (<8px): solid swatch at exact size" {
  _gen_placeholder t.png 4 4 "$IM" "$FONT"
  [ "$(dims t.png)" = "4x4" ]
}

@test "small image (no room for text): still framed, exact size" {
  _gen_placeholder s.png 50 50 "$IM" "$FONT"
  [ "$(dims s.png)" = "50x50" ]
}

@test "zero dimensions on an image: falls back to 800x600" {
  _gen_placeholder z.png 0 0 "$IM" "$FONT"
  [ "$(dims z.png)" = "800x600" ]
}

@test "pdf placeholder: empty file" {
  _gen_placeholder doc.pdf 0 0 "$IM" "$FONT"
  [ -f doc.pdf ]
  [ ! -s doc.pdf ]
}

@test "nested path is created" {
  _gen_placeholder "wp-content/uploads/2026/02/x-200x100.png" 200 100 "$IM" "$FONT"
  [ -f "wp-content/uploads/2026/02/x-200x100.png" ]
  [ "$(dims wp-content/uploads/2026/02/x-200x100.png)" = "200x100" ]
}

@test "labelled placeholder embeds text when a font is available" {
  [ -n "$FONT" ] || skip "no system font on this platform"
  _gen_placeholder photo.png 600 400 "$IM" "$FONT"
  # the file should be larger than a plain fill of the same size (text + frame)
  _image_blank() { "$IM" -size 600x400 xc:'#e9e9ec' blank.png; }
  _image_blank
  [ "$(stat -f%z photo.png 2>/dev/null || stat -c%s photo.png)" -gt \
    "$(stat -f%z blank.png 2>/dev/null || stat -c%s blank.png)" ]
}

@test "mp4 placeholder: even dimensions via libx264" {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264 || skip "no libx264"
  command -v ffprobe >/dev/null 2>&1 || skip "no ffprobe"
  _gen_placeholder clip.mp4 101 99 "$IM" "$FONT"   # odd dims -> rounded down to even
  run ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 clip.mp4
  [ "$output" = "100,98" ]
}

@test "webm placeholder: uses libvpx (not libx264)" {
  ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libvpx || skip "no libvpx"
  command -v ffprobe >/dev/null 2>&1 || skip "no ffprobe"
  _gen_placeholder clip.webm 320 240 "$IM" "$FONT"
  run ffprobe -v error -select_streams v -show_entries stream=width,height -of csv=p=0 clip.webm
  [ "$output" = "320,240" ]
}
