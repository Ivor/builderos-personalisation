# Video Recording

Two modes:

1. **Throwaway recordings** for inspection/debug — keep it simple, follow the *Quick recording* section.
2. **Demo videos for humans** — viewers need a visible cursor, predictable window placement, narration captions. Follow *Demo recordings*.

## Quick recording (headless, default)

```bash
S=session-$$
playwright-cli -s=$S open "<URL>"
playwright-cli -s=$S video-start
# ... actions ...
playwright-cli -s=$S video-stop
playwright-cli -s=$S close
```

Output lands in `.playwright-cli/video-<timestamp>.webm`. Always `video-stop` before `close` so the file flushes.

## Demo recordings (headed, captioned, narrated)

For videos a human will actually watch.

### 1. Use a config file, NOT the `resize` command

`playwright-cli resize W H` only resizes the page viewport. It does NOT control the OS-level browser window position/size, and it does NOT control the recorded video resolution. For demo videos, write a JSON config and pass it to `open --config=...`:

```json
{
  "browser": {
    "browserName": "chromium",
    "launchOptions": {
      "args": ["--window-position=0,0", "--window-size=1440,900"]
    },
    "contextOptions": {
      "viewport": { "width": 1440, "height": 900 }
    }
  },
  "saveVideo": { "width": 1440, "height": 900 }
}
```

```bash
playwright-cli -s=$S --config=./playwright-cli.json open "$URL" --headed
```

`launchOptions.args` controls where the OS window sits and how big its chrome is. `contextOptions.viewport` controls the page content area. `saveVideo` controls the output WebM resolution. All three need to agree for a clean recording.

Default to `1440x900` for laptop-friendly recordings; bump to `1920x1080` only when you've confirmed the display can fit it. If the OS window appears clipped off the right edge of the screen, it's the wrong size — the recording itself will be fine, but live preview won't be.

### 2. Inject a visible cursor (Chromium doesn't record the OS cursor)

Playwright recordings capture the page DOM, not the OS pointer. Without explicit cursor rendering, the video will show form fields filling themselves and buttons clicking themselves — confusing for viewers. Inject a CSS dot that tracks `mousemove`:

```js
async (page) => {
  const js = `
    (() => {
      if (window.__cursorInjected) return;
      window.__cursorInjected = true;
      const c = document.createElement("div");
      c.id = "__demo_cursor";
      c.style.cssText = "position:fixed;left:0;top:0;width:24px;height:24px;background:radial-gradient(circle,rgba(255,0,0,0.85) 0%,rgba(255,0,0,0.55) 60%,rgba(255,0,0,0) 100%);border:2px solid white;border-radius:50%;pointer-events:none;z-index:2147483647;transform:translate(-50%,-50%);transition:transform 0.05s linear";
      document.documentElement.appendChild(c);
      document.addEventListener("mousemove", (e) => { c.style.left = e.clientX + "px"; c.style.top = e.clientY + "px"; }, true);
      document.addEventListener("mousedown", () => { c.style.background = "radial-gradient(circle,rgba(0,180,0,0.95) 0%,rgba(0,180,0,0.6) 60%,rgba(0,180,0,0) 100%)"; }, true);
      document.addEventListener("mouseup", () => { c.style.background = "radial-gradient(circle,rgba(255,0,0,0.85) 0%,rgba(255,0,0,0.55) 60%,rgba(255,0,0,0) 100%)"; }, true);
      // Auto-accept data-confirm — see section 3.
      window.confirm = () => true;
    })();
  `;
  await page.addInitScript(js);
  await page.evaluate(js); // also inject into the current page
}
```

`addInitScript` runs the script on every NEW page navigation (full reload). On LiveView `push_navigate` (SPA-style), the `window` object persists, so the override stays in effect. The `evaluate(js)` call covers the initial page that was already loaded when the script was registered.

### 3. Bypass `data-confirm` dialogs

Phoenix LiveView's `data-confirm` attribute calls `window.confirm()`. `playwright-cli run-code` detects ANY open native dialog and **refuses to execute further code** until it's dismissed. Inline `page.once("dialog", d => d.accept())` and `waitForEvent("dialog")` patterns inside run-code don't fire fast enough — playwright-cli's modal-state guard checks first.

The robust workaround: override `window.confirm` to auto-return `true`, both via `addInitScript` (as part of the cursor injection above) AND defensively just before the action that would trigger it:

```js
async (page) => {
  await page.evaluate(() => { window.confirm = () => true; });
  await page.locator(...).click();
}
```

This sidesteps the dialog entirely — production code is unchanged, real users still see the confirm. Trade-off: the dialog is never rendered in the video. If the dialog needs to APPEAR in the video and then be accepted, that's a separate pattern requiring a non-`run-code` flow (call click without awaiting, sleep, then `playwright-cli dialog-accept`).

### 4. Wrap `run-code` — it returns 0 even on JS rejection

`playwright-cli run-code` exits 0 even when the inner promise rejects. A failed `locator.click({timeout: 5000})` or `waitFor` silently passes by exit code, but writes `### Error` or `TimeoutError` to stdout/stderr. Capture combined output and grep for those markers:

```bash
run_or_die() {
  local out
  out=$(playwright-cli -s="$S" run-code "$1" 2>&1)
  if echo "$out" | grep -qE '^### Error|^TimeoutError|^Error:|Error: locator'; then
    echo "=== PHASE FAILED ===" >&2
    echo "$out" | tail -20 >&2
    exit 1
  fi
}
```

Without this wrapper, failed steps record fake "success" timestamps in the narration log and the resulting video is a series of no-ops.

### 5. Locator regex `$` doesn't match HEEX-rendered text

`getByText(/\(copy\)$/)` will FAIL on text rendered through HEEX because templates emit trailing whitespace/newlines from indentation. The element's accessible text is `"\n  Renamed by X (copy)\n"`, not `"Renamed by X (copy)"`. Use `exact: false` substring matching:

```js
page.getByText("(copy)", { exact: false })
```

Or trim the regex: `/\(copy\)\s*$/`. Substring is simpler and works for all HEEX output.

### 6. Phase-bounded narration timestamps

Capture start AND end times around each phase so caption duration covers the whole action, not just the moment-before-trigger:

```bash
T0=$(python3 -c "import time; print(time.time())")
now() { python3 -c "import time; print(round(time.time() - ${T0}, 3))"; }

phase() {
  local label="$1" code="$2" start end
  start=$(now)
  run_or_die "$code"
  sleep "${DWELL:-4}"  # dwell on the post-action state for the caption to be read
  end=$(now)
  printf "%s\t%s\t%s\n" "$start" "$end" "$label" >> narration.log
}
```

The TSV format `<start>\t<end>\t<label>` plugs directly into a downstream ffmpeg pipeline (`subtitles=` filter or `drawtext`) for burned-in captions. See the `trim-idle-video` skill for the trim+caption tool.

### 7. Recording shutdown

```bash
playwright-cli -s=$S video-stop  # always before close
playwright-cli -s=$S close
latest_video=$(ls -1t .playwright-cli/video-*.webm 2>/dev/null | head -n1)
[ -n "$latest_video" ] || { echo "No recording found" >&2; exit 1; }
mv "$latest_video" ./<friendly-name>.webm
```

The file lands inside `.playwright-cli/`, which is relative to the CLI's working directory. If your script's cwd is already `.playwright-cli/`, the recording ends up in `.playwright-cli/.playwright-cli/video-*.webm` (double-nested). Either `cd` to the project root first, or be ready to fish it out of the nested path.

## When NOT to use headed mode

The default flow is headless. Pass `--headed` ONLY when:

- The user explicitly asks for a visible browser, OR
- You're producing a demo/walkthrough video where mouse motion matters.

Headed sessions steal focus and interrupt the user's workflow. Never use headed for routine login/automation steps.
