#!/bin/bash
#
# conf-to-epub.sh -- convert a session of LDS General Conference to an epub file

### PARSE ARGUMENTS ###

year="$1"
month="$2"
language="${3:-eng}"

if [ -z "$year" ] || [ -z "$month" ]; then
    echo USAGE: "$0 <year> <month> [<language>]"
    exit 1
fi

if [ "$(echo "$year" | grep -E -o '(19|20)[0-9][0-9]')" != "$year" ]; then
    echo Invalid year
    exit 1
fi

case "$month" in
    april|April|apr|Apr|4|04)
        month=04
        month_name=April
        ;;
    october|October|oct|Oct|10)
        month=10
        month_name=October
        ;;
    *)
        echo Invalid month
        exit 1
        ;;
esac

### SETUP VARIABLES ###

base_url="https://www.churchofjesuschrist.org"
conference_url="https://www.churchofjesuschrist.org/study/general-conference/$year/$month?lang=$language"
script_dir="$(cd "$(dirname "$0")" && pwd)"
build_dir="$(mktemp -d)"
metadata_file="$build_dir/title.txt"
build_files="$metadata_file"
trap "rm -rf '$build_dir'" EXIT

### LIST SESSIONS AND TALKS ###

echo Getting list of talks
talk_paths="$(
    curl --silent --location "$conference_url" | \
        htmlq --attribute href ".body nav a"
)"

if [ $? != 0 ]; then
    echo Failed to get a list of talks
    exit 1
fi

### DOWNLOAD COVER IMAGE ###

echo Getting cover image
listing_url="https://www.churchofjesuschrist.org/study/general-conference?lang=$language"
cover_img_url="$(
    curl --silent --location "$listing_url" | \
        htmlq "a[href*='/$year/$month'] img" --attribute src | \
        head -1 | \
        sed 's|/full/.*|/full/!2560,/0/default|'
)"

cover_file=""
if [ -n "$cover_img_url" ]; then
    cover_raw="$build_dir/cover-raw.jpg"
    cover_file="$build_dir/cover.jpg"
    curl --silent --location "$cover_img_url" > "$cover_raw"

    if command -v magick >/dev/null 2>&1; then
        echo Building cover

        # Kindle covers are 1:1.6. The artwork sits at the bottom, full width,
        # and a band in the artwork's average color fills the top for the title.
        cover_w=1600
        cover_h=2560
        min_band=427
        title_font=/System/Library/Fonts/Supplemental/Didot.ttc
        label_font=/System/Library/Fonts/Optima.ttc
        [ -f "$title_font" ] || title_font=Times-Roman
        [ -f "$label_font" ] || label_font=Helvetica

        art_file="$build_dir/cover-art.png"
        magick "$cover_raw" -resize "${cover_w}x" \
            -gravity center -crop "${cover_w}x$((cover_h - min_band))+0+0" +repage \
            "$art_file"
        band=$((cover_h - $(magick identify -format %h "$art_file")))
        band_color="$(magick "$cover_raw" -resize '1x1!' -modulate 45,80 -format '%[pixel:p{0,0}]' info:)"
        month_caps="$(echo "$month_name $year" | tr '[:lower:]' '[:upper:]')"

        magick -size "${cover_w}x${cover_h}" "xc:$band_color" \
            "$art_file" -gravity South -composite \
            -fill white -font "$title_font" -pointsize 130 \
            -gravity North -annotate +0+$((band / 2 - 150)) "General Conference" \
            -stroke 'rgba(255,255,255,0.6)' -strokewidth 3 \
            -draw "line 600,$((band / 2 + 20)) 1000,$((band / 2 + 20))" -stroke none \
            -font "$label_font" -pointsize 64 -kerning 20 \
            -annotate +0+$((band / 2 + 60)) "$month_caps" \
            \( -size "${cover_w}x160" 'xc:rgba(0,0,0,0.45)' \) -gravity South -composite \
            -fill 'rgba(255,255,255,0.9)' -pointsize 36 -kerning 6 \
            -annotate +0+62 "THE CHURCH OF JESUS CHRIST OF LATTER-DAY SAINTS" \
            -quality 90 "$cover_file"
    else
        echo Skipping text overlay because magick command not found
        cover_file="$cover_raw"
    fi
else
    echo Failed to find cover image, skipping
fi

### OUTPUT METADATA ###

echo Creating metadata
cat >"$metadata_file" <<EOF
---
title: $month_name $year General Conference
author: The Church of Jesus Christ of Latter-day Saints
---
EOF

### GET SESSION AND TALK CONTENT ###

echo Getting sessions and talks
for talk_path in $talk_paths; do
    echo Getting "$talk_path"
    url="$base_url$talk_path"
    name="$(echo "$talk_path" | grep -E -o '[^/]+$')"
    html_file="$build_dir/$name-raw.html"
    stage_file="$build_dir/$name-stage.html"

    curl --silent --location "$url" > "$html_file"
    title="$(htmlq --filename "$html_file" --text ".body h1")"
    subtitle="$(htmlq --filename "$html_file" --text ".body .subtitle")"
    author="$(htmlq --filename "$html_file" --text ".body .byline .author-name")"
    [ -z "$author" ] && author="$(htmlq --filename "$html_file" --text ".body .byline p:first-of-type")"
    role="$(htmlq --filename "$html_file" --text ".body .byline .author-role")"
    [ -z "$role" ] && role="$(htmlq --filename "$html_file" --text ".body .byline p:nth-of-type(2)")"
    summary="$(htmlq --filename "$html_file" --text ".body .kicker")"

    [ -n "$subtitle" ] && title="$title $subtitle"
    author="$(echo "$author" | sed 's/^By /by /')"
    author_name="$(echo "$author" | sed -E 's/^(Presented )?[Bb]y +//')"

    # the author goes in the heading so it shows in the table of contents, but
    # style.css hides it on the page, where the byline below already shows it
    toc_author=""
    [ -n "$author_name" ] && toc_author=" <span class=\"toc-author\">($author_name)</span>"

    echo "<h1>$title$toc_author</h1>" >"$stage_file"
    [ -n "$author" ] && echo "<p><em>$author</em></p>" >>"$stage_file"
    [ -n "$role" ] && echo "<p><em>$role</em></p>" >>"$stage_file"
    [ -n "$summary" ] && echo "<p><em>$summary</em><p>" >>"$stage_file"

    # only include body for talks, not sessions
    if [ "${name%-session}" = "$name" ]; then
        htmlq --filename "$html_file" ".body .body-block" >>"$stage_file"
    fi

    # building the epub from markdown works much better than HTML, so convert to
    # markdown, removing footnotes and adding the hostname to link URLs
    talk_file="$build_dir/$name.md"

    pandoc -f html -t commonmark --wrap none -o - "$stage_file" | \
        sed \
        -e 's#\[<sup>[0-9]\+</sup>\]([^)]*)##g' \
        -e 's#<a [^>]*><sup>[0-9]\+</sup></a>##g' \
        -e "s#\](/#]($base_url/#g" \
        -e "s#href=\"/#href=\"$base_url/#g" \
        >"$talk_file"
    build_files="$build_files $talk_file"
done

### CONVERT TO EPUB ###

echo Converting to epub

dir="conferences/$year/$month"
mkdir -p "$dir"
file_base="$dir/general-conference-$year-$month-$language"

cover_args=""
if [ -n "$cover_file" ] && [ -f "$cover_file" ]; then
    cover_args="--epub-cover-image=$cover_file"
fi

pandoc \
    --split-level 1 \
    --toc --toc-depth 1 \
    --css "$script_dir/style.css" \
    $cover_args \
    -o "$file_base.epub" \
    $build_files

### CONVERT TO AZW3 AND BACK ###

ebook_convert=""
if command -v ebook-convert >/dev/null 2>&1; then
    ebook_convert="ebook-convert"
elif [ -x /Applications/calibre.app/Contents/MacOS/ebook-convert ]; then
    ebook_convert="/Applications/calibre.app/Contents/MacOS/ebook-convert"
fi

if [ -n "$ebook_convert" ]; then
    echo Converting to azw3 and back
    "$ebook_convert" "$file_base.epub" "$file_base.azw3"
    "$ebook_convert" "$file_base.azw3" "$file_base.converted.epub"
    rm -f "$file_base.azw3"
else
    echo Skipping convertion to azw3 and back because ebook-convert command not found
fi
