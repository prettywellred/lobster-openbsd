This fork includes fixes to run Lobster reliably on OpenBSD.

## Why an OpenBSD fork exists
Upstream versions assume GNU userland behaviors (notably GNU sed). BSD sed differs in important ways. (More on that ahead.)

Years back, a previous version of the script was working for me without much hassle... but some matter of commits later, I suddenly had bugs I did not ever manage to properly debug myself. 

I wish I could say that since then I have very seriously leveled up, but the fact is that ChatGPT turned out to be very halpful when I decided to revisit this issue with its help.

The rest of this README will be straight from ChatGPT for now. I intend to revisit both the code and the documentation in the near future and ensure it is as clean and correct as possible. 

## Key portability fixes included
- **BSD sed tab behavior:** `\t` in sed replacement is not a literal tab on BSD sed.
  Any logic that emits TSV using sed `...\t...` can be corrupted (e.g., IDs become `Season 1t68101`),
  causing invalid URLs and curl errors.
- **Avoid sed “slurp” parsing:** `sed ':a;N;$!ba;...'` reads the whole HTML into pattern space.
  On BSD sed/regex this can become extremely slow (“hang”) on large pages.
- **Perl-based extractors:** HTML extraction is implemented using `perl -0777` so parsing remains fast
  and emits real tab separators reliably.
- **Curl hardening:** curl wrapper unsets proxy env vars, can force IPv4, and uses timeouts; in debug
  mode it can print verbose trace output to `/dev/tty`.

## Requirements
- `curl`, `fzf` (or `rofi` if using external menu)
- `mpv` (or another configured player)
- `perl` (included in OpenBSD base)

## Debugging
Run with:
- `-x` to enable debug trace.
If a request stalls, debug mode prints curl verbose output to the terminal so you can see whether the
delay is DNS, TLS, HTTP, or parsing.

## Status / Compatibility
- Confirmed working on: OpenBSD (one workstation)
- Other BSDs: unverified. I intend to find this out soon and update the project accordingly. 
