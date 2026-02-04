#!/usr/bin/env sh

LOBSTER_VERSION="4.6.0"

### General Variables ###
config_file="$HOME/.config/lobster/lobster_config.sh"
lobster_editor=${VISUAL:-${EDITOR}}
tmp_dir="${TMPDIR:-/tmp}/lobster" && mkdir -p "$tmp_dir"
lobster_socket="${TMPDIR:-/tmp}/lobster.sock" # Used by mpv (check the play_video function)
lobster_logfile="${TMPDIR:-/tmp}/lobster.log"
tty="${TTY:-/dev/tty}"
applications="$HOME/.local/share/applications/lobster" # Used for external menus (for now just rofi)
images_cache_dir="$tmp_dir/lobster-images"             # Used for storing downloaded images of movie covers
STATE=""                                               # Used for main state machine

# Constants
nl='
' # Literal newline for use in pattern matching
# These are not arbitrary, but determined by rofi kb-custom-1 and kb-custom-2 exit codes
BACK_CODE=10
FORWARD_CODE=11
API_URL="https://dec.eatmynerds.live"

### Notifications ###
command -v notify-send >/dev/null 2>&1 && notify="true" || notify="false" # check if notify-send is installed
# send_notification [message] [timeout] [icon] [title]
send_notification() {
    [ "$json_output" = "true" ] && return
    if [ "$use_external_menu" = "false" ] || [ -z "$use_external_menu" ]; then
        # stdout/stderr are redirected to the logfile later; always show messages on the user's terminal
        [ -z "$4" ] && printf "\33[2K\r\033[1;34m%s\n\033[0m" "$1" >"$tty" 2>/dev/null && return
        [ -n "$4" ] && printf "\33[2K\r\033[1;34m%s - %s\n\033[0m" "$1" "$4" >"$tty" 2>/dev/null && return
    fi
    [ -z "$2" ] && timeout=3000 || timeout="$2" # default timeout is 3 seconds
    if [ "$notify" = "true" ]; then
        [ -z "$3" ] && notify-send "$1" "$4" -t "$timeout" -h string:x-dunst-stack-tag:vol # override previous notifications
        [ -n "$3" ] && notify-send "$1" "$4" -t "$timeout" -i "$3" -h string:x-dunst-stack-tag:vol
    fi
}

### OpenBSD / portability helpers ###
curl_get() {
    # In debug mode, show curl trace on your terminal so hangs are obvious
    if [ "$debug" = "true" ]; then
        printf "curl_get: %s\n" "$*" >"$tty" 2>/dev/null
        _curl_stderr="$tty"
        _curl_verbose="-v"
        _curl_silent=""
    else
        _curl_stderr="$lobster_logfile"
        _curl_verbose=""
        _curl_silent="-sS"
    fi

    # Hard-kill wrapper (avoids cases where curl wedges beyond --max-time)
    # Uses perl alarm, which exists on OpenBSD base.
    perl -e '
        $SIG{ALRM} = sub { die "curl timeout\n" };
        alarm 30;
        exec @ARGV;
    ' \
    env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        curl -4 -f $_curl_silent -L $_curl_verbose \
        --noproxy '*' \
        --connect-timeout 10 \
        --max-time 25 \
        -H "User-Agent: lobster/${LOBSTER_VERSION}" \
        "$@" \
    2>>"$_curl_stderr"
}

# Portable in-place sed: works on OpenBSD/BSD/GNU
sedi() {
    _expr=$1
    _file=$2
    if sed -i '' -e "$_expr" "$_file" 2>/dev/null; then return 0; fi
    if sed -i -e "$_expr" "$_file" 2>/dev/null; then return 0; fi
    if sed -i.bak -e "$_expr" "$_file" 2>/dev/null; then rm -f "$_file.bak" 2>/dev/null; return 0; fi
    _tmp=$(mktemp "${TMPDIR:-/tmp}/lobster.sed.XXXXXX") || return 1
    sed -e "$_expr" "$_file" >"$_tmp" && cat "$_tmp" >"$_file"
    rm -f "$_tmp" 2>/dev/null
}

### HTML Decoding ###
command -v "hxunent" >/dev/null 2>&1 && hxunent="hxunent" || hxunent="tee /dev/null" # use hxunent if installed, else do nothing

### Discord Rich Presence Variables ###
# Note: experimental feature
presence_client_id="1239340948048187472" # Discord Client ID
# shellcheck disable=SC2154
discord_ipc="${XDG_RUNTIME_DIR}/discord-ipc-0" # Discord IPC Socket
handshook="$tmp_dir/handshook"                 # Indicates if the RPC handshake has been done
ipclog="$tmp_dir/ipclog"                       # Logs the RPC events
presence="$tmp_dir/presence"                   # Used by the rich presence function
small_image="https://www.pngarts.com/files/9/Juvenile-American-Lobster-PNG-Transparent-Image.png"

### OS Specific Variables ###
separator=':'             # default value
path_thing="\\"           # default value
sed='sed'                 # default value
ueberzugpp_tmp_dir="/tmp" # for some reason ueberzugpp only uses $TMPDIR on Darwin
# shellcheck disable=SC2249
case "$(uname -s)" in
    MINGW* | *Msys) separator=';' && path_thing='' ;;
    *arwin) sed="gsed" && ueberzugpp_tmp_dir="${TMPDIR:-/tmp}" ;;
esac

# Checks if any of the provided arguments are -e or --edit
if printf "%s" "$*" | grep -qE "\-\-edit|\-e" 2>/dev/null; then
    #shellcheck disable=1090
    . "${config_file}"
    [ -z "$lobster_editor" ] && lobster_editor="nano"
    "$lobster_editor" "$config_file"
    exit 0
fi

### Cleanup Functions ###
rpc_cleanup() {
    pkill -f "nc -U $discord_ipc" >/dev/null
    pkill -f "tail -f $presence" >/dev/null
    rm "$handshook" "$ipclog" "$presence" >/dev/null
}
cleanup() {
    [ "$debug" != "true" ] && rm -rf "$tmp_dir"
    [ "$remove_tmp_lobster" = "true" ] && rm -rf "$tmp_dir"

    if [ "$image_preview" = "true" ] && [ "$use_external_menu" = "false" ] && [ "$use_ueberzugpp" = "true" ]; then
        killall ueberzugpp 2>/dev/null
        rm -f "$ueberzugpp_tmp_dir"/ueberzugpp-*
    fi
    set +x && exec 2>&-
}
trap cleanup EXIT INT TERM

### Help Function ###
usage() {
    printf "
  Usage: %s [options] [query]
  If a query is provided, it will be used to search for a Movie/TV Show

  Options:
    -c, --continue
      Continue watching from current history
    -d, --download [path]
      Downloads movie or episode that is selected (if no path is provided, it defaults to the current directory)
    --discord, --discord-presence, --rpc, --presence
      Enables discord rich presence (beta feature, but should work fine on Linux)
    -e, --edit
      Edit config file using an editor defined with lobster_editor in the config (\$EDITOR by default)
    -h, --help
      Show this help message and exit
    -i, --image-preview
      Shows image previews during media selection (requires chafa, you can optionally use ueberzugpp)
    -j, --json
      Outputs the json containing video links, subtitle links, referrers etc. to stdout
    -l, --language [language]
      Specify the subtitle language (if no language is provided, it defaults to english)
    --rofi, --external-menu
      Use rofi instead of fzf
    -n, --no-subs
      Disable subtitles
    -p, --provider
      Specify the provider to watch from (if no provider is provided, it defaults to Vidcloud) (currently supported: Vidcloud, UpCloud)
    -q, --quality
      Specify the video quality (if no quality is provided, it defaults to 1080)
    -r, --recent [movies|tv]
      Lets you select from the most recent movies or tv shows (if no argument is provided, it defaults to movies)
    -s, --syncplay
      Use Syncplay to watch with friends
    -t, --trending
      Lets you select from the most popular movies and shows
    -u, -U, --update
      Update the script
    -v, -V, --version
      Show the version of the script
    -x, --debug
      Enable debug mode (prints out debug info to stdout and also saves it to \$TEMPDIR/lobster.log)

" "${0##*/}"
}

### Dependencies Check ###
dep_ch() {
    for dep; do
        if ! command -v "$dep" >/dev/null; then
            send_notification "Program \"$dep\" not found. Please install it."
            exit 1
        fi
    done
}

### Helpers ###
sanitize_lang() {
    # Strip leading whitespace, then strip any leading non-alnum "marker" characters,
    # then lowercase. This avoids BSD sed character-range pitfalls.
    _l=$(printf "%s" "$1" | $sed -e 's/^[[:space:]]*//' -e 's/^[^[:alnum:]]*[[:space:]]*//')
    printf "%s" "$_l" | tr '[:upper:]' '[:lower:]'
}

### Default Configuration ###
configuration() {
    [ -n "$XDG_CONFIG_HOME" ] && config_dir="$XDG_CONFIG_HOME/lobster" || config_dir="$HOME/.config/lobster"
    [ -n "$XDG_DATA_HOME" ] && data_dir="$XDG_DATA_HOME/lobster" || data_dir="$HOME/.local/share/lobster"
    [ ! -d "$config_dir" ] && mkdir -p "$config_dir"
    [ ! -d "$data_dir" ] && mkdir -p "$data_dir"
    #shellcheck disable=1090
    [ -f "$config_file" ] && . "${config_file}"
    [ -z "$base" ] && base="flixhq.to"
    [ -z "$player" ] && player="mpv"
    [ -z "$download_dir" ] && download_dir="$PWD"
    [ -z "$provider" ] && provider="Vidcloud"
    [ -z "$subs_language" ] && subs_language="english"
    subs_language="$(sanitize_lang "$subs_language")"
    [ -z "$histfile" ] && histfile="$data_dir/lobster_history.txt" && mkdir -p "$(dirname "$histfile")"
    [ -z "$history" ] && history=false
    [ -z "$use_external_menu" ] && use_external_menu="false"
    [ -z "$image_preview" ] && image_preview="false"
    [ -z "$debug" ] && debug="false"
    [ -z "$preview_window_size" ] && preview_window_size=right:60%:wrap
    if [ -z "$use_ueberzugpp" ]; then
        use_ueberzugpp="false"
    elif [ "$use_ueberzugpp" = "true" ]; then
        [ -z "$ueberzug_x" ] && ueberzug_x=10
        [ -z "$ueberzug_y" ] && ueberzug_y=3
        [ -z "$ueberzug_max_width" ] && ueberzug_max_width=$(($(tput lines) / 2))
        [ -z "$ueberzug_max_height" ] && ueberzug_max_height=$(($(tput lines) / 2))
    fi
    [ -z "$remove_tmp_lobster" ] && remove_tmp_lobster="true"
    [ -z "$json_output" ] && json_output="false"
    [ -z "$discord_presence" ] && discord_presence="false"
    case "$(uname -s)" in
        MINGW* | *Msys)
            if [ -z "$watchlater_dir" ]; then
                case "$(command -v "$player")" in
                    *scoop*) watchlater_dir="$HOMEPATH/scoop/apps/mpv/current/portable_config/watch_later/" ;;
                    *) watchlater_dir="$LOCALAPPDATA/mpv/watch_later" ;;
                esac
            fi
            ;;
        *) [ -z "$watchlater_dir" ] && watchlater_dir="$tmp_dir/watchlater" && mkdir -p "$watchlater_dir" ;;
    esac
}

# Logging redirection
exec 3>&1 4>&2 1>"$lobster_logfile" 2>&1
{
    dep_ch "grep" "$sed" "curl" "fzf" || true
    if [ "$use_external_menu" = "true" ]; then
        dep_ch "rofi" || true
    fi
    if [ "$player" = "mpv" ]; then
        dep_ch "awk" "nc" || true
    fi

    generate_desktop() {
        cat <<EOF
[Desktop Entry]
Name=$1
Exec=echo %k %c
Icon=$2
Type=Application
Categories=lobster;
EOF
    }

    launcher() {
        case "$use_external_menu" in
            "true")
                [ -z "$2" ] && rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -sort -dmenu -i -width 1500 -p "" -mesg "$1"
                [ -n "$2" ] && rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -sort -dmenu -i -width 1500 -p "" -mesg "$1" -display-columns "$2"
                rc=$?
                ;;
            *)
                [ -z "$2" ] && fzf_out=$(fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --prompt "$1")
                [ -n "$2" ] && fzf_out=$(fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --prompt "$1" --with-nth "$2" -d "\t")
                rc=$?
                case $fzf_out in
                    shift-left"$nl"*)
                        rc="$BACK_CODE"
                        fzf_out=${fzf_out#*"$nl"}
                        ;;
                    "$nl"*) fzf_out=${fzf_out#"$nl"} ;;
                    *) exit 1 ;;
                esac
                printf '%s\n' "$fzf_out"
                ;;
        esac
        return "$rc"
    }

    nth() {
        stdin=$(cat -)
        [ -z "$stdin" ] && return 1
        prompt="$1"
        [ $# -ne 1 ] && shift
        line=$(printf "%s" "$stdin" | $sed -nE "s@^(.*)\t[0-9:]*\t[0-9]*\t(tv|movie)(.*)@\1 (\2)\t\3@p" | cut -f1-3,6,7 | tr '\t' '|' | launcher "$prompt" | cut -d "|" -f 1)
        [ -n "$line" ] && printf "%s" "$stdin" | $sed -nE "s@^$line\t(.*)@\1@p" || exit 1
    }

    prompt_to_continue() {
        if [ "$media_type" = "tv" ]; then
            continue_choice=$(printf "Next episode\nReplay episode\nExit\nSearch" | launcher "Select: ")
        else
            continue_choice=$(printf "Exit\nSearch" | launcher "Select: ")
        fi
        rc=$?
        [ "$rc" -eq "$BACK_CODE" ] && exit 0
    }

    get_input() {
        if [ "$use_external_menu" = "false" ]; then
            printf "Search Movie/TV Show: " >"$tty"
            read -r query
        else
            if [ -n "$rofi_prompt_config" ]; then
                query=$(printf "" | rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -theme "$rofi_prompt_config" -sort -dmenu -i -width 1500 -p "" -mesg "Search Movie/TV Show")
            else
                query=$(printf "" | launcher "Search Movie/TV Show")
            fi
        fi
        rc=$?
        [ "$rc" -gt 1 ] && exit 0
        [ -n "$query" ] && query=$(echo "$query" | tr ' ' '-')
        if [ -z "$query" ]; then
            send_notification "Error" "1000" "" "No query provided"
            exit 1
        fi
    }

		search() {
    		url="https://${base}/search/$1"
    		send_notification "Fetching search page…" "1500" "" "$url"

 		   html_file="$tmp_dir/search.html"
    		rm -f "$html_file" 2>/dev/null

 		   # Download to file first (decouples curl from the parsing pipeline)
    		if ! curl_get -o "$html_file" "$url"; then
        		send_notification "Error" "3000" "" "Failed to fetch search page"
        		exit 1
    		fi

    # Show size so we know we're parsing real content
    if [ "$debug" = "true" ]; then
        sz=$(wc -c <"$html_file" 2>/dev/null | tr -d ' ')
        printf "search(): downloaded %s bytes\n" "${sz:-?}" >"$tty" 2>/dev/null
    fi

    # Fast newline flattening, then split entries by flw-item marker
		response=$(
    perl -0777 -ne '
        while (
            /class="flw-item".*?img\s+data-src="([^"]+)".*?
             <a\s+href="[^"]*\/(tv|movie)\/watch-[^"]*?-([0-9]+)".*?
             title="([^"]+)".*?
             class="fdi-item">([^<]+)</sgx
        ) {
            print "$1\t$3\t$2\t$4 [$5]\n";
        }
    ' "$html_file"
)

    if [ -z "$response" ]; then
        # Helpful hint: often Cloudflare returns a page but the HTML layout changes
        send_notification "Error" "4000" "" "No parseable results (site HTML changed / CF page?)"
        exit 1
    fi

    if [ "$debug" = "true" ]; then
        cnt=$(printf "%s\n" "$response" | wc -l | tr -d ' ')
        printf "search(): parsed %s results\n" "${cnt:-0}" >"$tty" 2>/dev/null
    fi
}

    choose_search() {
        if [ -z "$response" ]; then
            [ -z "$query" ] && get_input
            search "$query"
            [ -z "$response" ] && exit 1
        fi
        STATE="MEDIA"
    }

    choose_media() {
        if [ "$image_preview" = "true" ]; then
            if [ "$use_external_menu" = "false" ] && [ "$use_ueberzugpp" = "true" ]; then
                command -v "ueberzugpp" >/dev/null || send_notification "Please install ueberzugpp if you want to use it for image previews"
                use_ueberzugpp="false"
            fi
            maybe_download_thumbnails "$response"
            select_desktop_entry ""
            rc=$?
        else
            if [ "$use_external_menu" = "true" ]; then
                choice=$(printf "%s" "$response" | rofi -kb-mode-next "" -kb-mode-previous "" -kb-custom-1 Shift+Left -kb-custom-2 Shift+Right -dmenu -i -p "" -mesg "Choose a Movie or TV Show" -display-columns 4)
                rc=$?
            else
                choice=$(printf "%s" "$response" | fzf --bind "shift-right:accept" --expect=shift-left --cycle --reverse --with-nth 4 -d "\t" --header "Choose a Movie or TV Show")
                rc=$?
                case $choice in
                    shift-left"$nl"*)
                        rc="$BACK_CODE"
                        choice=${choice#*"$nl"}
                        ;;
                    "$nl"*) choice=${choice#"$nl"} ;;
                    *) exit 1 ;;
                esac
            fi
            image_link=$(printf "%s" "$choice" | cut -f1)
            media_id=$(printf "%s" "$choice" | cut -f2)
            title=$(printf "%s" "$choice" | $sed -nE "s@.* *(tv|movie)[[:space:]]*(.*) \[.*\]@\2@p")
            media_type=$(printf "%s" "$choice" | $sed -nE "s@.* *(tv|movie)[[:space:]]*(.*) \[.*\]@\1@p")
        fi

        if [ "$rc" -eq "$BACK_CODE" ]; then
            STATE="SEARCH"
            response=""
            query=""
            choice=""
            return 0
        elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
            exit 0
        fi

        if [ "$media_type" = "tv" ]; then
            STATE="SEASON"
        else
            keep_running="true"
            STATE="PLAY"
        fi
    }

		choose_season() {
  	 		season_line=$(
       		curl_get "https://${base}/ajax/v2/tv/seasons/${media_id}" |
       		perl -0777 -ne '
           		while (/href="[^"]*-([0-9]+)">(.*?)<\/a>/sg) {
               		$t=$2; $t =~ s/<[^>]+>//g; $t =~ s/^\s+|\s+$//g;
               		next if $t eq "";
               		print "$t\t$1\n";
          		 }
      		 ' |
      		 launcher "Select a season: " "1"
   		)
   		rc=$?

		   if [ "$rc" -eq "$BACK_CODE" ]; then
   		    STATE="MEDIA"
      		 return 0
   		elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
       		exit 0
   		fi

 		  [ -z "$season_line" ] && exit 1

			season_title=$(printf '%s' "$season_line" | cut -f1)
			season_id=$(printf '%s' "$season_line" | cut -f2)
			STATE="EPISODE"
		}

		choose_episode() {
    		ep_line=$(
        		curl_get "https://${base}/ajax/v2/season/episodes/${season_id}" |
    		    perl -0777 -ne '
        		    while (/class="nav-item".*?data-id="([0-9]+)".*?title="([^"]+)"/sg) {
            		    $id=$1; $t=$2;
              		  $t =~ s/^\s+|\s+$//g;
               		 print "$t\t$id\n";
            		}
       		 ' |
        		$hxunent |
       		 launcher "Select an episode: " "1"
    		)
    		rc=$?

 		   if [ "$rc" -eq "$BACK_CODE" ]; then
    		    STATE="SEASON"
       		 return 0
    		elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$FORWARD_CODE" ]; then
        		exit 0
    		fi

		    episode_title=$(printf '%s' "$ep_line" | cut -f1)
    		data_id=$(printf '%s' "$ep_line" | cut -f2)

 		   episode_id=$(
    		    curl_get "https://${base}/ajax/v2/episode/servers/${data_id}" |
        		perl -0777 -ne '
            		while (/class="nav-item".*?data-id="([0-9]+)".*?title="([^"]+)"/sg) {
                		print "$1\t$2\n";
          		  }
        		' |
        		grep "$provider" | cut -f1 | head -n1
   		 )

 		   keep_running="true"
    		STATE="PLAY"
		}


		    next_episode_exists() {
    		    episodes_list=$(
    		curl_get "https://${base}/ajax/v2/season/episodes/${season_id}" |
    		perl -0777 -ne '
        		while (/class="nav-item".*?data-id="([0-9]+)".*?title="([^"]+)"/sg) {
            		print "$2\t$1\n";
       		 }
    		' | $hxunent
		)
				next_episode=$(printf "%s" "$episodes_list" | $sed -n "/$data_id/{n;p;}")
        [ -n "$next_episode" ] && return
#PASTEHERE 

				[ -z "$tmp_season_id" ] && return
        season_title=$(printf "%s" "$tmp_season_id" | cut -f1)
        season_id=$(printf "%s" "$tmp_season_id" | cut -f2)
        next_episode=$(curl_get "https://${base}/ajax/v2/season/episodes/${season_id}" | $sed ':a;N;$!ba;s/\n//g;s/class="nav-item"/\n/g' |
            $sed -nE "s@.*data-id=\"([0-9]*)\".*title=\"([^\"]*)\">.*@\2\t\1@p" | $hxunent | head -1)
        [ -n "$next_episode" ] && return
    }

    ### Image Preview ###
    maybe_download_thumbnails() {
        need_dl=0
        tab="$(printf '\t')"
        while IFS="$tab" read -r cover_url id type title; do
            [ -z "$cover_url" ] && continue
            poster="$images_cache_dir/  $title ($type)  $id.jpg"
            [ ! -f "$poster" ] && need_dl=1 && break
        done <<EOF
$1
EOF

        if [ "$need_dl" -eq 1 ]; then
            rm -f "$images_cache_dir"/* 2>/dev/null
            download_thumbnails "$1"
        fi
    }

    download_thumbnails() {
        pids=""
        while IFS='     ' read -r cover_url id type title; do
            [ -z "$cover_url" ] && continue
            printf '%s\n' "$cover_url" >"$tmp_dir/image_links"

            cover_url=$(printf '%s\n' "$cover_url" | sed -E 's:/[0-9]+x[0-9]+/:/1000x1000/:')
            poster_path="$images_cache_dir/  $title ($type)  $id.jpg"
            curl_get -o "$poster_path" "$cover_url" >/dev/null 2>&1 &
            pids="$pids $!"

            if [ "$use_external_menu" = "true" ]; then
                entry="$tmp_dir/applications/$id.desktop"
                generate_desktop "$title ($type)  $id" "$poster_path" >"$entry" &
                pids="$pids $!"
            fi
        done <<EOF
$1
EOF

        for pid in $pids; do
            wait "$pid" 2>/dev/null
        done
    }

    image_preview_fzf() {
        if [ "$use_ueberzugpp" = "true" ]; then
            # uuidgen isn't guaranteed on OpenBSD; mktemp is.
            UB_PID_FILE=$(mktemp "${TMPDIR:-/tmp}/lobster.ubpid.XXXXXX") || exit 1
            if [ -z "$ueberzug_output" ]; then
                ueberzugpp layer --no-stdin --silent --use-escape-codes --pid-file "$UB_PID_FILE"
            else
                ueberzugpp layer -o "$ueberzug_output" --no-stdin --silent --use-escape-codes --pid-file "$UB_PID_FILE"
            fi
            UB_PID="$(cat "$UB_PID_FILE")"
            LOBSTER_UEBERZUG_SOCKET="$ueberzugpp_tmp_dir/ueberzugpp-$UB_PID.socket"
            choice=$(find "$images_cache_dir" -type f -exec basename {} \; | fzf --bind "shift-right:accept" --expect=shift-left --cycle -i -q "$1" --cycle --preview-window="$preview_window_size" --preview="ueberzugpp cmd -s $LOBSTER_UEBERZUG_SOCKET -i fzfpreview -a add -x $ueberzug_x -y $ueberzug_y --max-width $ueberzug_max_width --max-height $ueberzug_max_height -f $images_cache_dir/{}" --reverse --with-nth 2 -d "  ")
            rc=$?

            case $choice in
                shift-left"$nl"*)
                    rc="$BACK_CODE"
                    choice=${choice#*"$nl"}
                    ;;
                "$nl"*) choice=${choice#"$nl"} ;;
                *) exit 1 ;;
            esac
            ueberzugpp cmd -s "$LOBSTER_UEBERZUG_SOCKET" -a exit
            rm -f "$UB_PID_FILE" 2>/dev/null
        else
            dep_ch "chafa" || true
            [ "$TERM_PROGRAM" = "vscode" ] && fmt="-f sixels --margin-bottom 8" || fmt=""
            [ -n "$chafa_dims" ] && dim="-s $chafa_dims"
            choice=$(find "$images_cache_dir" -type f -exec basename {} \; | fzf \
                --bind "shift-right:accept" --expect=shift-left --cycle -i -q "$1" \
                --preview-window="$preview_window_size" \
                --preview="chafa $fmt $dim $images_cache_dir/{}" \
                --reverse --with-nth 2 -d "  ")
            rc=$?

            case $choice in
                shift-left"$nl"*)
                    rc="$BACK_CODE"
                    choice=${choice#*"$nl"}
                    ;;
                "$nl"*) choice=${choice#"$nl"} ;;
                *) exit 1 ;;
            esac
        fi
        return "$rc"
    }

    select_desktop_entry() {
        if [ "$use_external_menu" = "true" ]; then
            if [ -n "$image_config_path" ]; then
                rofi_out=$(rofi -show drun -drun-categories lobster -filter "$1" -show-icons -theme "$image_config_path")
            else
                rofi_out=$(rofi -show drun -drun-categories lobster -filter "$1" -show-icons)
            fi
            rc=$?
            choice=$(echo "$rofi_out" | $sed -nE "s@.*/([0-9]*)\.desktop@\1@p") 2>/dev/null

            [ -z "$choice" ] && exit 0

            media_id=$(printf "%s" "$choice" | cut -d\  -f1)
            title=$(printf "%s" "$choice" | $sed -nE "s@[0-9]* (.*) \((tv|movie)\)@\1@p")
            media_type=$(printf "%s" "$choice" | $sed -nE "s@[0-9]* (.*) \((tv|movie)\)@\2@p")
        else
            image_preview_fzf "$1"
            rc=$?
            tput reset
            media_id=$(printf "%s" "$choice" | $sed -nE 's@.* ([0-9]+)\.jpg@\1@p')
            title=$(printf "%s" "$choice" | $sed -nE 's@^[[:space:]]*(.*) \((tv|movie)\)  [0-9]+\.jpg@\1@p')
            media_type=$(printf "%s" "$choice" | $sed -nE 's@^[[:space:]]*(.*) \((tv|movie)\)  [0-9]+\.jpg@\2@p')
        fi
        return "$rc"
    }

    ### Scraping/Decryption ###
    get_embed() {
        if [ "$media_type" = "movie" ]; then
            movie_page="https://${base}"$(curl_get "https://${base}/ajax/movie/episodes/${media_id}" |
                $sed ':a;N;$!ba;s/\n//g;s/class="nav-item"/\n/g' | $sed -nE "s@.*href=\"([^\"]*)\"[[:space:]]*title=\"${provider}\".*@\1@p")
            episode_id=$(printf "%s" "$movie_page" | $sed -nE "s_.*-([0-9]*)\.([0-9]*)\$_\2_p")
        fi
        embed_link=$(curl_get "https://${base}/ajax/episode/sources/${episode_id}" | $sed -nE "s_.*\"link\":\"([^\"]*)\".*_\1_p")
        if [ -z "$embed_link" ]; then
            send_notification "Error" "Could not get embed link"
            exit 1
        fi
    }

    extract_from_embed() {
        api_url="${API_URL}/?url=${embed_link}"
        json_data=$(curl_get "${api_url}")
        video_link=$(printf "%s" "$json_data" | $sed -nE "s_.*\"file\":\"([^\"]*\.m3u8)\".*_\1_p" | head -1)

        [ -n "$quality" ] && video_link=$(printf "%s" "$video_link" | sed -e "s|/playlist.m3u8|/$quality/index.m3u8|")

        [ "$json_output" = "true" ] && printf "%s\n" "$json_data" && exit 0

        if [ "$no_subs" = "true" ]; then
            send_notification "Continuing without subtitles"
        else
            subs_links=$(printf "%s" "$json_data" | tr '{' '\n' | awk -v lang="$(sanitize_lang "$subs_language")" ' { if (match($0,/"file":"([^"]+)"/,f) && match($0,/"label":"([^"]+)"/,lb)) { if (index(tolower(lb[1]), lang) > 0) print f[1]; } } ')

            if [ -z "$subs_links" ]; then
                send_notification "No subtitles found for language '$subs_language'"
                subs_arg=""
            else
                subs_arg="--sub-file"
                num_subs=$(printf "%s" "$subs_links" | wc -l)
                if [ "$num_subs" -gt 0 ]; then
                    subs_links=$(printf "%s" "$subs_links" | sed -e "s/:/\\$path_thing:/g" -e "H;1h;\$!d;x;y/\n/$separator/" -e "s/$separator\$//")
                    subs_arg="--sub-files"
                fi
            fi
        fi
    }

    ### History ###
    check_history() {
        if [ ! -f "$histfile" ]; then
            [ "$image_preview" = "true" ] && send_notification "Now Playing" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
            [ "$json_output" != "true" ] && send_notification "Now Playing" "5000" "" "$title"
            return
        fi
        case $media_type in
            movie)
                if grep -q "$media_id" "$histfile"; then
                    resume_from=$(grep "$media_id" "$histfile" | cut -f2)
                    send_notification "Resuming from" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$resume_from"
                else
                    send_notification "Now Playing" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                fi
                ;;
            tv)
                if grep -q "$media_id" "$histfile"; then
                    if grep -q "$episode_id" "$histfile"; then
                        [ -z "$resume_from" ] && resume_from=$($sed -nE "s@.*\t([0-9:]*)\t$media_id\ttv\t$season_id.*@\1@p" "$histfile")
                        send_notification "$season_title" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$episode_title"
                    fi
                else
                    send_notification "$season_title" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$episode_title"
                fi
                ;;
            *) send_notification "This media type is not supported" ;;
        esac
    }

    save_history() {
        [ -z "$image_link" ] && image_link="$(grep "$media_id" "$tmp_dir/image_links" | cut -f1)"
        case $media_type in
            movie)
                if [ "$progress" -gt "90" ]; then
                    _mid=$(printf "%s" "$media_id" | sed 's/[\/&]/\\&/g')
                    sedi "/$_mid/d" "$histfile"
                    send_notification "Deleted from history" "5000" "" "$title"
                else
                    if grep -q -- "$media_id" "$histfile" 2>/dev/null; then
                        _mid=$(printf "%s" "$media_id" | sed 's/[\/&]/\\&/g')
                        _pos=$(printf "%s" "$position" | sed 's/[\/&]/\\&/g')
                        sedi "s|\t[0-9:]*\t$_mid|\t$_pos\t$_mid|1" "$histfile"
                        send_notification "Saved to history" "5000" "" "$title"
                    else
                        printf "%s\t%s\t%s\t%s\t%s\n" "$title" "$position" "$media_id" "$media_type" "$image_link" >>"$histfile"
                        send_notification "Saved to history" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                    fi
                fi
                ;;
            tv)
                if [ "$progress" -gt "90" ]; then
                    next_episode_exists
                    if [ -n "$next_episode" ]; then
                        position="00:00:00"
                        episode_title=$(printf "%s" "$next_episode" | cut -f1)
                        data_id=$(printf "%s" "$next_episode" | cut -f2)
                        episode_id=$(
                            curl_get "https://${base}/ajax/v2/episode/servers/${data_id}" |
                            perl -0777 -ne '
                                while (/class="nav-item".*?data-id="([0-9]+)".*?title="([^"]+)"/sg) {
                                    print "$1\t$2\n";
                                }
                            ' |
                            grep -m1 -F "$provider" | cut -f1
                        )
   
                        send_notification "Updated to next episode" "5000" "" "$episode_title"
                    else
                        _mid=$(printf "%s" "$media_id" | sed 's/[\/&]/\\&/g')
                        sedi "/$_mid/d" "$histfile"
                        send_notification "Completed" "5000" "" "$title"
                        return
                    fi
                else
                    send_notification "Saved to history" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                fi

                    if grep -q -- "$media_id" "$histfile" 2>/dev/null; then
                    _mid=$(printf "%s" "$media_id" | sed 's/[\/&]/\\&/g')
                    _rep=$(printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
                        "$title" "$position" "$media_id" "$media_type" \
                        "$season_id" "$episode_id" "$season_title" "$episode_title" "$data_id" "$image_link" \
                        | sed 's/[\/&]/\\&/g')
                    sedi "s|^.*\t$_mid\t.*$|$_rep|" "$histfile"
                else
                    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$title" "$position" "$media_id" "$media_type" \
                        "$season_id" "$episode_id" "$season_title" "$episode_title" "$data_id" "$image_link" >>"$histfile"
                fi
                ;;
            *) notify-send "Error" "Unknown media type" ;;
        esac
    }

    play_from_history() {
        [ ! -f "$histfile" ] && send_notification "No history file found" "5000" "" && exit 1
        [ "$watched_history" = 1 ] && exit 0
        watched_history=1

        if [ "$image_preview" = "true" ]; then
            test -d "$images_cache_dir" || mkdir -p "$images_cache_dir"
            if [ "$use_external_menu" = "true" ]; then
                mkdir -p "$tmp_dir/applications/"
                [ ! -L "$applications" ] && ln -sf "$tmp_dir/applications/" "$applications"
            fi
            history_response=$(
                awk -F'\t' '
                {
                    title = $1
                    id    = $3
                    type  = $4
                    cover_url = (type == "tv") ? $10 : $5
                    print cover_url "\t" id "\t" type "\t" title
                }
                ' "$histfile"
            )

            maybe_download_thumbnails "$history_response"
            select_desktop_entry ""
            if [ "$media_type" = "tv" ]; then
                line=$(grep -m1 -F "$media_id" "$histfile")
                season_id=$(printf "%s" "$line" | cut -f5)
                episode_id=$(printf "%s" "$line" | cut -f6)
                season_title=$(printf "%s" "$line" | cut -f7)
                episode_title=$(printf "%s" "$line" | cut -f8)
                data_id=$(printf "%s" "$line" | cut -f9)
                image_link=$(printf "%s" "$line" | cut -f10)
            fi
        else
            choice=$($sed -n "1h;1!{x;H;};\${g;p;}" "$histfile" | nl -w 1 | nth "Choose an entry: ")
            [ -z "$choice" ] && exit 1
            title=$(printf "%s" "$choice" | cut -f1)
            resume_from=$(printf "%s" "$choice" | cut -f2)
            media_id=$(printf "%s" "$choice" | cut -f3)
            media_type=$(printf "%s" "$choice" | cut -f4)
            if [ "$media_type" = "tv" ]; then
                season_id=$(printf "%s" "$choice" | cut -f5)
                episode_id=$(printf "%s" "$choice" | cut -f6)
                season_title=$(printf "%s" "$choice" | cut -f7)
                episode_title=$(printf "%s" "$choice" | cut -f8)
                data_id=$(printf "%s" "$choice" | cut -f9)
                image_link=$(printf "%s" "$choice" | cut -f10)
            fi
        fi

        STATE="PLAY" && keep_running="true" && loop
    }

    ### Discord Rich Presence ###
    set_activity() {
        len=${#1}
        printf "\\001\\000\\000\\000"
        for i in 0 8 16 24; do
            len=$((len >> i))
            printf "\\$(printf "%03o" "$len")"
        done
        printf "%s" "$1"
    }

    update_rich_presence() {
        state=$1
        payload='{"cmd":"SET_ACTIVITY","args":{"pid":"786","activity":{"state":"'"$state"'","details":"'"$displayed_title"'","assets":{"large_image":"'"$image_link"'","large_text":"'"$title"'","small_image":"'"$small_image"'","small_text":"powered by lobster"}}},"nonce":"'"$(date)"'"}'
        if [ ! -e "$handshook" ]; then
            handshake='{"v":1,"client_id":"'$presence_client_id'"}'
            printf "\\000\\000\\000\\000\\$(printf "%03o" "${#handshake}")\\000\\000\\000%s" "$handshake" >"$presence"
            sleep 2
            touch "$handshook"
        fi
        set_activity "$payload" >"$presence"
    }

    update_discord_presence() {
        total=$(printf "%02d:%02d:%02d" $((total_duration / 3600)) $((total_duration % 3600 / 60)) $((total_duration % 60)))
        [ -z "$image_link" ] && image_link="$(grep "$media_id" "$tmp_dir/image_links" | cut -f1)"
        sleep 2

        while :; do
            if command -v nc >/dev/null 2>&1 && [ -S "$lobster_socket" ] 2>/dev/null; then
                position=$(echo '{ "command": ["get_property", "time-pos"] }' | nc -U "$lobster_socket" 2>/dev/null | head -1)
                [ -z "$position" ] && break
                position=$(printf "%s" "$position" | sed -nE "s@.*\"data\":([0-9]*)\..*@\1@p")
                position=$(printf "%02d:%02d:%02d" $((position / 3600)) $((position % 3600 / 60)) $((position % 60)))
                update_rich_presence "$(printf "%s / %s" "$position" "$total")" &
            else
                sleep 5
                update_rich_presence "Watching" &
            fi
            sleep 0.5
        done

        rpc_cleanup
    }

    save_progress() {
        position=$(cat "$watchlater_dir/"* 2>/dev/null | grep -A1 "$video_link" | $sed -nE "s@start=([0-9.]*)@\1@p" | cut -d'.' -f1)
        if [ -n "$position" ]; then
            progress=$((position * 100 / total_duration))
            position=$(printf "%02d:%02d:%02d" $((position / 3600)) $((position / 60 % 60)) $((position % 60)))
            send_notification "Stopped at" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$position"
        fi
    }

    play_video() {
        [ "$media_type" = "tv" ] && displayed_title="$title - $season_title - $episode_title" || displayed_title="$title"
        case $player in
            iina | celluloid)
                if [ -n "$subs_links" ]; then
                    [ "$player" = "iina" ] && iina --no-stdin --keep-running --mpv-sub-files="$subs_links" --mpv-force-media-title="$displayed_title" "$video_link"
                    [ "$player" = "celluloid" ] && celluloid --mpv-sub-files="$subs_links" --mpv-force-media-title="$displayed_title" "$video_link" 2>/dev/null
                else
                    [ "$player" = "iina" ] && iina --no-stdin --keep-running --mpv-force-media-title="$displayed_title" "$video_link"
                    [ "$player" = "celluloid" ] && celluloid --mpv-force-media-title="$displayed_title" "$video_link" 2>/dev/null
                fi
                ;;
            vlc)
                vlc_subs_links=$(printf "%s" "$subs_links" | sed 's/https\\:/https:/g; s/:\([^\/]\)/#\1/g')
                vlc "$video_link" --meta-title "$displayed_title" --input-slave="$vlc_subs_links"
                ;;
            mpv | mpv.exe)
                [ -z "$continue_choice" ] && check_history
                player_cmd="$player"
                [ -n "$resume_from" ] && player_cmd="$player_cmd --start='$resume_from'"
                [ -n "$subs_links" ] && player_cmd="$player_cmd $subs_arg='$subs_links'"
                escaped_title=$(printf "%s" "$displayed_title" | "$sed" "s/'/'\\\\''/g")
                player_cmd="$player_cmd --force-media-title='$escaped_title' '$video_link'"
                case "$(uname -s)" in
                    MINGW* | *Msys) player_cmd="$player_cmd --write-filename-in-watch-later-config --save-position-on-quit --quiet" ;;
                    *) player_cmd="$player_cmd --watch-later-directory='$watchlater_dir' --write-filename-in-watch-later-config --save-position-on-quit --quiet" ;;
                esac

                if command -v nc >/dev/null 2>&1 && [ -S "$lobster_socket" ] 2>/dev/null; then
                    player_cmd="$player_cmd --input-ipc-server='$lobster_socket'"
                fi

                eval "$player_cmd" >&3 &

                if [ -z "$quality" ]; then
                    link=$(printf "%s" "$video_link" | $sed "s/\/playlist.m3u8/\/1080\/index.m3u8/g")
                else
                    link=$video_link
                fi

                content=$(curl_get "$link")
                durations=$(printf "%s" "$content" | grep -oE 'EXTINF:[0-9.]+,' | cut -d':' -f2 | tr -d ',')
                total_duration=$(printf "%s" "$durations" | xargs echo | awk '{for(i=1;i<=NF;i++)sum+=$i} END {print sum}' | cut -d'.' -f1)

                [ "$discord_presence" = "true" ] && update_discord_presence
                wait
                save_progress
                ;;
            mpv_android) nohup am start --user 0 -a android.intent.action.VIEW -d "$video_link" -n is.xyz.mpv/.MPVActivity -e "title" "$displayed_title" >/dev/null 2>&1 & ;;
            iSH)
                if [ -n "$subs_links" ]; then
                    first_sub=$(printf "%s" "$subs_links" | sed 's/https\\:/https:/g; s/:\([^\/]\)/#\1/g')
                else
                    first_sub=""
                fi
                printf "\e]8;;vlc-x-callback://x-callback-url/stream?url=%s&sub=%s\a~ Tap to open VLC ~\e]8;;\a\n" "$video_link" "$first_sub"
                sleep 5
                ;;
            *yncpla*) nohup "syncplay" "$video_link" -- --force-media-title="${displayed_title}" >/dev/null 2>&1 & ;;
            *) $player "$video_link" ;;
        esac
    }

    update_script() {
        which_lobster="$(command -v lobster)"
        [ -z "$which_lobster" ] && send_notification "Can't find lobster in PATH"
        [ -z "$which_lobster" ] && exit 1
        update=$(curl_get "https://raw.githubusercontent.com/justchokingaround/lobster/main/lobster.sh" || exit 1)
        update="$(printf '%s\n' "$update" | diff -u "$which_lobster" -)"
        if [ -z "$update" ]; then
            send_notification "Script is up to date :)"
        else
            if printf '%s\n' "$update" | patch "$which_lobster" -; then
                send_notification "Script has been updated!"
            else
                send_notification "Can't update for some reason!"
            fi
        fi
        exit 0
    }

    download_video() {
        title="$(printf "%s" "$2" | tr -d ':/')"
        dir="${3}/${title}"
        language="$(sanitize_lang "$subs_language")"
        num_subs="$(printf "%s" "$subs_links" | sed 's/:\([^\/]\)/\n\\1/g' | wc -l)"
        ffmpeg_subs_links=$(printf "%s" "$subs_links" | sed 's/:\([^\/]\)/\nh/g; s/\\:/:/g' | while read -r sub_link; do
            printf " -i %s" "$sub_link"
        done)

        sub_ops=""
        ffmpeg_meta=""
        ffmpeg_maps=""

        if [ "$no_subs" = "true" ]; then
            sub_ops=""
        else
            sub_ops="$ffmpeg_subs_links -map 0:v -map 0:a"
            if [ "$num_subs" -eq 0 ]; then
                sub_ops=" -i $subs_links -map 0:v -map 0:a -map 1"
                ffmpeg_meta="-metadata:s:s:0 language=$language"
            else
                for i in $(seq 1 "$num_subs"); do
                    ffmpeg_maps="$ffmpeg_maps -map $i"
                    ffmpeg_meta="$ffmpeg_meta -metadata:s:s:$((i - 1)) language=$(printf "%s_%s" "$language" "$i")"
                done
            fi
            sub_ops="$sub_ops $ffmpeg_maps -c:v copy -c:a copy -c:s srt $ffmpeg_meta"
        fi

        # shellcheck disable=SC2086
        ffmpeg -loglevel error -stats -i "$1" $sub_ops -c copy "$dir.mkv"
    }

    choose_from_trending_or_recent() {
        path=$1
        section=$2
        if [ "$path" = "home" ]; then
            response=$(curl_get "https://${base}/${path}" | $sed -n "/id=\"${section}\"/,/class=\"block_area block_area_home section-id-02\"/p" | $sed ':a;N;$!ba;s/\n//g;s/class="flw-item"/\n/g' |
                $sed -nE "s@.*img data-src=\"([^\"]*)\".*<a href=\".*/(tv|movie)/watch-.*-([0-9]*)\".*title=\"([^\"]*)\".*class=\"fdi-item\">([^<]*)</span>.*@\1\t\3\t\2\t\4 [\5]@p" | $hxunent)
        else
            response=$(curl_get "https://${base}/${path}" | $sed ':a;N;$!ba;s/\n//g;s/class="flw-item"/\n/g' |
                $sed -nE "s@.*img data-src=\"([^\"]*)\".*<a href=\".*/(tv|movie)/watch-.*-([0-9]*)\".*title=\"([^\"]*)\".*class=\"fdi-item\">([^<]*)</span>.*@\1\t\3\t\2\t\4 [\5]@p" | $hxunent)
        fi
        main
    }

    loop() {
        while [ "$keep_running" = "true" ]; do
            get_embed
            [ -z "$embed_link" ] && exit 1
            extract_from_embed
            [ -z "$video_link" ] && exit 1
            if [ "$download" = "true" ]; then
                if [ "$media_type" = "movie" ]; then
                    if [ "$image_preview" = "true" ]; then
                        download_video "$video_link" "$title" "$download_dir" "$json_data" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" &
                        send_notification "Finished downloading" "5000" "$images_cache_dir/  $title ($media_type)  $media_id.jpg" "$title"
                    else
                        download_video "$video_link" "$title" "$download_dir" "$json_data" &
                        send_notification "Finished downloading" "5000" "" "$title"
                    fi
                else
                    if [ "$image_preview" = "true" ]; then
                        download_video "$video_link" "$title - $season_title - $episode_title" "$download_dir" "$json_data" "$images_cache_dir/  $title - $season_title - $episode_title ($media_type)  $media_id.jpg" &
                        send_notification "Finished downloading" "5000" "$images_cache_dir/  $title - $season_title - $episode_title ($media_type)  $media_id.jpg" "$title - $season_title - $episode_title"
                    else
                        download_video "$video_link" "$title - $season_title - $episode_title" "$download_dir" "$json_data" &
                        send_notification "Finished downloading" "5000" "" "$title - $season_title - $episode_title"
                    fi
                fi
                exit
            fi
            if [ "$discord_presence" = "true" ]; then
                [ -p "$presence" ] || mkfifo "$presence"
                rm -f "$handshook" >/dev/null
                tail -f "$presence" | nc -U "$discord_ipc" >"$ipclog" &
                update_rich_presence "00:00:00" &
            fi
            play_video
            next_episode=""
            if [ -n "$position" ] && [ "$history" = "true" ]; then
                save_history
            fi
            prompt_to_continue
            case "$continue_choice" in
                "Next episode")
                    resume_from=""
                    if [ -z "$next_episode" ]; then
                        next_episode_exists
                    fi
                    if [ -n "$next_episode" ]; then
                        episode_title=$(printf "%s" "$next_episode" | cut -f1)
                        data_id=$(printf "%s" "$next_episode" | cut -f2)
                        episode_id=$(
											    curl_get "https://${base}/ajax/v2/episode/servers/${data_id}" |
											    perl -0777 -ne '
     											  while (/class="nav-item".*?data-id="([0-9]+)".*?title="([^"]+)"/sg) {
            									print "$1\t$2\n";
        										}
    											' |
    											grep -m1 -F "$provider" | cut -f1
												)
												send_notification "Watching the next episode" "5000" "" "$episode_title"
                    else
                        send_notification "No more episodes" "5000" "" "$title"
                        exit 0
                    fi
                    continue
                    ;;
                "Replay episode")
                    resume_from=""
                    continue
                    ;;
                "Search")
                    rm -f "$images_cache_dir"/*
                    query=""
                    response=""
                    season_id=""
                    episode_id=""
                    episode_title=""
                    title=""
                    data_id=""
                    resume_from=""
                    main
                    ;;
                *) keep_running="false" && exit ;;
            esac
        done
    }

    main() {
        STATE="SEARCH"
        while :; do
            case "$STATE" in
                SEARCH) choose_search ;;
                MEDIA) choose_media ;;
                SEASON) choose_season ;;
                EPISODE) choose_episode ;;
                PLAY) loop ;;
                EXIT) break ;;
                *) break ;;
            esac
        done
    }

    configuration

    if [ "$player" = "mpv" ] && ! command -v mpv >/dev/null; then
        if command -v mpv.exe >/dev/null; then
            player="mpv.exe"
        elif uname -a | grep -q "android" 2>/dev/null; then
            player="mpv_android"
        elif uname -a | grep -q "ish" 2>/dev/null; then
            player="iSH"
        else
            dep_ch mpv.exe
        fi
    fi

    [ "$debug" = "true" ] && set -x
    query=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --)
                shift
                query="$*"
                break
                ;;
            -c | --continue) play_from_history && exit ;;
            --discord | --discord-presence | --rpc | --presence) discord_presence="true" && shift ;;
            -d | --download)
                download="true"
                if [ -n "$download_dir" ]; then
                    shift
                else
                    download_dir="$2"
                    if [ -z "$download_dir" ]; then
                        download_dir="$PWD"
                        shift
                    else
                        if [ "${download_dir#-}" != "$download_dir" ]; then
                            download_dir="$PWD"
                            shift
                        else
                            shift 2
                        fi
                    fi
                fi
                ;;
            -h | --help) usage && exit 0 ;;
            -i | --image-preview) image_preview="true" && shift ;;
            -j | --json) json_output="true" && shift ;;
            -l | --language)
                subs_language="$2"
                if [ -z "$subs_language" ]; then
                    subs_language="english"
                    shift
                else
                    if [ "${subs_language#-}" != "$subs_language" ]; then
                        subs_language="english"
                        shift
                    else
                        subs_language="$(sanitize_lang "$subs_language")"
                        shift 2
                    fi
                fi
                ;;
            --rofi | --external-menu) use_external_menu="true" && shift ;;
            -p | --provider)
                provider="$2"
                if [ -z "$provider" ]; then
                    provider="Vidcloud"
                    shift
                else
                    if [ "${provider#-}" != "$provider" ]; then
                        provider="Vidcloud"
                        shift
                    else
                        shift 2
                    fi
                fi
                ;;
            -q | --quality)
                quality="$2"
                if [ -z "$quality" ]; then
                    quality="1080"
                    shift
                else
                    if [ "${quality#-}" != "$quality" ]; then
                        quality="1080"
                        shift
                    else
                        shift 2
                    fi
                fi
                ;;
            -r | --recent)
                recent="$2"
                if [ -z "$recent" ]; then
                    recent="movie"
                    shift
                else
                    if [ "${recent#-}" != "$recent" ]; then
                        recent="movie"
                        shift
                    else
                        shift 2
                    fi
                fi
                ;;
            -s | --syncplay) player="syncplay" && shift ;;
            -t | --trending) trending="1" && shift ;;
            -u | -U | --update) update_script ;;
            -v | -V | --version) send_notification "Lobster Version: $LOBSTER_VERSION" && exit 0 ;;
            -x | --debug)
                set -x
                debug="true"
                shift
                ;;
            -n | --no-subs)
                no_subs="true" && shift
                ;;
            *)
                query="$query $1"
                shift
                ;;
        esac
    done

    query="$(printf "%s" "$query" | tr ' ' '-' | $sed "s/^-//g")"

    if [ "$image_preview" = "true" ]; then
        test -d "$images_cache_dir" || mkdir -p "$images_cache_dir"
        if [ "$use_external_menu" = "true" ]; then
            mkdir -p "$tmp_dir/applications/"
            [ ! -L "$applications" ] && ln -sf "$tmp_dir/applications/" "$applications"
        fi
    fi

    [ -z "$provider" ] && provider="Vidcloud"
    [ "$trending" = "1" ] && choose_from_trending_or_recent "home" "trending-movies"
    [ "$recent" = "movie" ] && choose_from_trending_or_recent "movie" ""
    [ "$recent" = "tv" ] && choose_from_trending_or_recent "tv-show" ""

    main

} 2>&1 | tee "$lobster_logfile" >&3 2>&4
exec 1>&3 2>&4
