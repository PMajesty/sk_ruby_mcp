# SK Ruby MCP

An MCP server that runs inside desktop SketchUp as a Ruby extension. Any MCP client that speaks HTTP connects to `http://127.0.0.1:7891/mcp` and gets the document tools, `execute_ruby`, `model_look`, the architect pack (`place_box`, `place_perimeter`, `list_groups`, `site_metrics`, `grid_openings`) and the façade pack (`facade_faces`, `facade_place_openings`, `facade_place_bands`, `facade_paint`, `facade_list`, `facade_remove`, `facade_verify`, `facade_capture`). All of those tools are on by default. Turn a pack off from **Plugins → SK Ruby MCP → Settings…** if you want a smaller `tools/list`.

No second process, no modelling UI, no gems. Ruby stdlib only. Settings use SketchUp's own dialog, not a web page.

## Why

- Community SketchUp MCP servers are a Python process talking to a Ruby socket, and they assume one model is already open. None of them open, switch, save or close files.
- Trimble's SketchUp Connector for Claude runs in the cloud, only creates new files, and only works with Claude.

## Requirements

- SketchUp 2022 or newer, desktop. Developed and tested on macOS with SketchUp 2022. Windows code paths exist but are untested.
- Nothing else. The server uses only the Ruby that ships with SketchUp (2.7 in 2022, 3.x later).

## Install

1. Copy `sk_ruby_mcp.rb` and the `sk_ruby_mcp/` folder into SketchUp's Plugins folder:
   - macOS: `~/Library/Application Support/SketchUp 2022/SketchUp/Plugins`
   - Windows: `%APPDATA%\SketchUp\SketchUp 2022\SketchUp\Plugins`

   Replace `2022` with your version. In the Ruby console, `Sketchup.find_support_file("Plugins")` prints the exact path.
2. Restart SketchUp. The extension is enabled by default and starts the server about one second after load. **Plugins → SK Ruby MCP** can start or stop the server, show status, and edit settings.
3. Check it:

   ```sh
   curl http://127.0.0.1:7891/health
   ```

   Returns a small JSON object with uptime, request and tick counters. It says nothing about the model; use `model_status` for that.

The server logs only errors to the Ruby console. For everything else, use **Plugins → SK Ruby MCP → Status**, or:

```ruby
SkRubyMcp::App.print_status   # running/stopped, URL, applied settings, health
SkRubyMcp::App.stop
SkRubyMcp::App.start
```

## Connect a client

Cursor, `.cursor/mcp.json`:

```json
{ "mcpServers": { "sketchup": { "url": "http://127.0.0.1:7891/mcp" } } }
```

Claude Code:

```sh
claude mcp add --transport http sketchup http://127.0.0.1:7891/mcp
```

Anything that speaks MCP over Streamable HTTP works the same way, including Codex, LM Studio, Open WebUI and your own scripts: plain JSON responses, no SSE, no session header, no batches, MCP protocol versions `2024-11-05` through `2025-11-25`. Stdio-only clients need a bridge such as `mcp-remote`. `localhost` works too: the server binds both `127.0.0.1` and `::1`.

## Tools

| Tool | Arguments | Does |
|---|---|---|
| `model_status` | `wait_s` 0..15 | What is focused plus a cheap model summary: face count, bounds in metres, display units, tags, materials, selection, up to 20 top-level groups and components with names and bounds. Call first, and after any `opening` reply. |
| `model_look` | `view`, `width`, `height` | A JPEG of the focused viewport, returned as MCP image content. Optional `view`: `current` (default), `iso`, `plan`, `front`, `right`. Named views frame the model and restore the architect's camera. Do not poll this; `model_status` is the cheap picture. |
| `model_open` | `path`, `if_unsaved` | Open an existing `.skp`. Also the switch: the focused document is closed first. |
| `model_new` | `if_unsaved` | Blank document. |
| `model_save` | `mode` `in_place` / `save_as` / `copy`, `path`, `version` | `in_place` only for a file this session opened or saved. `save_as` moves the model to `path`. `copy` writes `path` and keeps focus; `version` (a year such as `2017`) writes the copy for an older SketchUp. |
| `model_close` | `if_unsaved` | Close the focused document. |
| `model_revert` | none | Discard unsaved changes and reload the last save. |
| `execute_ruby` | `code`, `operation_name`, `wrap_in_operation`, `timeout_s` | All modelling. |

Architect pack, on by default. Turn it off with **Plugins → SK Ruby MCP → Settings…** (`architect_pack` false) and restart if the server did not restart itself.

| Tool | Arguments | Does |
|---|---|---|
| `place_box` | `size_m`, `origin_m`, `name`, `storeys`, `tag`, `color` | Axis-aligned box in metres as a named group. Optional stacked floor groups. |
| `place_perimeter` | `site_w_m`, `site_d_m`, `depth_m`, `height_m`, `origin_m`, `storeys`, `name_*` | Four courtyard wings with no doubled corners. Reply includes union footprint and coverage. |
| `list_groups` | `max_depth`, `max_items` | Nested groups with bounds in metres. Deeper than `model_status`. |
| `site_metrics` | `site_w_m`, `site_d_m`, `site_area_m2`, `storey_h_m`, `min_height_m` | Footprint, coverage, crude GFA. `groups_union_m2` is the XY union of top-level boxes. Groups shorter than `min_height_m` (default 1 m) are skipped. |
| `grid_openings` | `group_name`, `facing`, `cols`, `rows`, `width_m`, `height_m`, `sill_m`, `margin_m`, `all_storeys`, `skip_ground`, `skip_storeys` | Punch a regular window grid on a named façade. `sill_m` is the first-row height; leftover height is not pushed under the first row. `all_storeys` punches nested floor groups; `skip_storeys` drops that many lowest floors (`skip_ground` is 1). |

Façade pack, on by default. Turn it off the same way (`facade_pack` false). It details one named group or component at a time from a schedule, and never cuts the wall: openings are glued cutting components, bands are proud groups, so `facade_remove` gives the plain mass back. Paths in arguments must be absolute (SketchUp resolves relative paths against its own working directory).

| Tool | Arguments | Does |
|---|---|---|
| `facade_faces` | `object`, `camera` or `camera_file`, `image_width`, `image_height`, `min_area_m2`, `min_dot`, `make_unique`, `write_to` | Vertical faces of the object that face the camera, ordered left to right as the camera sees them: sizes, world corners, the pixel quad of each face in an image of that size, storey levels read from thin floor plates and storey cells. Face ids feed every other façade tool; `write_to` saves the same reply as JSON for scripts. |
| `facade_place_openings` | `object`, `items`, `defaults`, `replace` | Windows and doors from a schedule. Each item: `face`, `kind` (`small_window`, `large_window`, `glass_door`, `storefront`, `custom`), horizontal `x0`/`x1` fractions of the face width (or `u0_m` + `width_m`, or `x_center` + `width_m`), vertical `storey` / `storeys` (list or `"all"`) or `z0_m`/`z1_m`, `count` to spread copies inside `x0..x1`, `frame_edges`, `frame_w_m`, `frame_out_m`, `recess_m`, `frame_color`, `glass_color`, `mullions`, `transom`, `label`. Overlapping openings and columns that do not fit are rejected per item. One undo step. |
| `facade_place_bands` | `object`, `z_m`, `faces`, `thickness_m`, `depth_m`, `color`, `inset_m`, `align`, `label` | Belt courses, cornices and plinths as thin proud groups at world heights. |
| `facade_paint` | `object`, `faces`, `color`, `material`, `texture`, `texture_size_m`, `clear` | Paint the object or given faces; openings and bands keep their own colours. |
| `facade_list` | `object`, `role` | Openings and bands on the object with the values they were placed with, plus whether each opening is still glued. |
| `facade_remove` | `object`, `role`, `faces`, `ids` | Erase façade elements by role, face or id; the wall under them is untouched. |
| `facade_verify` | `object`, `items`, `defaults`, `tol_m` | Resolve the schedule exactly as `facade_place_openings` would and diff it with the model: `matched`, `mismatched`, `missing`, `extra`, `schedule_errors`. |
| `facade_capture` | `image_path`, `width`, `height`, `camera` or `camera_file`, `object`, `isolate`, `id_pass`, `edges`, `background`, `hide_facade`, `keep_camera`, `antialias`, `transparent` | Clean PNG with a given camera and flat render settings; `id_pass objects|faces` paints flat id colours on black and writes the colour table next to the image as `<image>.colors.json`. Everything is restored afterwards. |

`bin/sk-facade-resolve FACES.json SCHEDULE.json` resolves a schedule offline with the same code the tool uses, so scripts can validate before touching SketchUp. Relief defaults (frame 0.15 m proud, recess 0.25 m, bands 0.2 m) are deliberately deep: shallower relief z-fights the wall when the camera stands a kilometre away.

Reply conventions, the same for every tool:

- JSON in `structuredContent` and as pretty-printed text. Tool failures come back as `isError: true`, not as JSON-RPC errors.
- `state` is `active`, `no_document`, `opening` or `failed`. `path` is the real path on disk, `null` for Untitled. `temporary: true` means the document is a scratch blank; call `model_save` with `save_as` before treating it as finished.
- A failure has `error` (a code such as `unsaved_changes`, `unnamed_save`, `newer_sketchup_file`, `busy`), `message`, `retry`, `next` (what to call) and sometimes `instead` (which tool).
- Nothing is saved or discarded without `if_unsaved`. A dirty document fails with `unsaved_changes` until the caller passes `if_unsaved=save` (allowed only for files this session opened or saved) or `if_unsaved=discard`.
- Open, new and revert wait up to 15 s inside the call. If SketchUp is still loading, they return `state: opening`; poll `model_status` with `wait_s=15` until `active` or `failed`.
- One tool call at a time. A concurrent call gets `error: busy` with `retry: true`. `model_status` is exempt so a client can always ask what is going on.
- `model_look` adds a second `content` item `{ type: "image", mimeType: "image/jpeg", data: "<base64>" }`. The JSON twin does not include the pixels. Default size is 1280×720; the server shrinks the JPEG if it would blow the 1 MiB reply cap.

The server also publishes a short `skmcp://howto` resource and an `instructions` string in `initialize`, so a model that has read nothing but `tools/list` can do real work.

## execute_ruby

- Runs in the focused document with SketchUp's full API. Use `Sketchup.active_model`; nothing is injected.
- Every call is exactly one undo step: committed on success, aborted whole on any exception. Pass `wrap_in_operation: false` only for read-only queries (reported as `undo_step: none`).
- The last expression comes back as `return_value` (`inspect`, capped at 32 KiB). `stdout` and `stderr` are captured, 64 KiB each. Long collections are summarised.
- Local variables, constants and helper methods persist between calls on the same document and are cleared on a document switch (`scope_reset: true`).
- Default time limit 30 s (`timeout_s`, max 3600). Pure Ruby is interrupted; a native SketchUp call that runs past the limit cannot be, and blocks every other request, `/health` included, until it returns. The reply says which happened.
- Refused for the duration of the call: `exit!`, `exec`, `system`, `spawn`, backticks, `IO.popen`, `fork`, `Thread.new`, `Process.kill`, `Sketchup.quit`, `Sketchup.open_file`, `Sketchup.file_new`. `exit` is ignored. Documents go through the `model_*` tools.
- Lengths are inches unless written like `10.m`. The tool description carries the handful of SketchUp facts models get wrong (`add_face` returning nil, `pushpull` direction, groups sharing definitions).

## Settings

Stored with `Sketchup.write_default` under section `SkRubyMcp`. Change them from **Plugins → SK Ruby MCP → Settings…**. That dialog writes the values and restarts the MCP server when a running value changed (port, packs, token, timeouts). **Start server**, **Stop server** and **Status** are on the same menu. The Ruby console still works.

| Key | Default | Range |
|---|---|---|
| `port` | `7891` | 1024..65535 |
| `auto_start` | `true` | |
| `architect_pack` | `true` | named massing tools |
| `facade_pack` | `true` | named façade tools |
| `pump_interval` | `0.02` s | 0.01..1.0 |
| `auth_token` | `""` (off) | any string |
| `wrap_in_operation` | `true` | default for `execute_ruby` |
| `execution_timeout_s` | `30.0` | 0.05..3600 |

```ruby
SkRubyMcp::Settings.set('port', 7892)
SkRubyMcp::Settings.set('auth_token', 'long-random-string')
SkRubyMcp::App.stop; SkRubyMcp::App.start
```

## Security

- Binds `127.0.0.1` and `::1` only. The `Host` header must be loopback; an `Origin` header, if present, must be loopback over `http`. Anything else is 403.
- With `auth_token` set, every request needs `Authorization: Bearer <token>` or gets 401. Cursor can send it via `"headers"` in `mcp.json`.
- `execute_ruby` is unsandboxed Ruby with the privileges of the SketchUp process. Anything that can reach the port can do anything you can. Keep it on one machine.

## How it works

- Single-threaded and cooperative. A `UI.start_timer` tick (every `pump_interval`) accepts, reads and answers non-blocking sockets on SketchUp's main thread. No Ruby threads. The server runs only while SketchUp's event loop ticks and dies with SketchUp.
- Opening and creating documents is fire-and-forget on the SketchUp side. The HTTP connection is parked and finished on a later tick, up to 15 s in-call; the pending operation itself gives up at 30 s. Each tick does at most one document mutation.
- macOS opens files through Launch Services (`open -b`). Windows opens in-process with `Sketchup.open_file`: the current document is closed on one tick and the file is opened on the next, and a failed status code is a tool error rather than a hang. The `.skp` header is read first: non-SketchUp files are refused, and SketchUp 2022 refuses files written by a newer major version because the version dialog would hang the tool.
- Revert has no SketchUp API: it closes without saving and reopens the last saved path.
- `model_new` uses `Sketchup.file_new`; when SketchUp yields a non-empty template instead of a blank, the bundled `assets/blank.skp` is copied to a temp path and opened, and the reply carries `temporary: true`.

## Limitations

- `model_look` photographs the live viewport. A hidden or zero-size window can yield a blank or tiny image; named views (`iso`, `plan`, `front`, `right`) still frame the model. The shot is JPEG, not a photoreal render.
- Editing by hand while a tool call is in flight is not supported. Edit when the agent is idle.

## Development

Unit tests run without SketchUp (fakes live in `test/test_helper.rb`) and need only `minitest`:

```sh
bin/sk-mcp-test    # runs the suite on every Ruby it finds (rbenv 2.7.8, Homebrew, rbenv 3.3.0), then ruby -c
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require "./#{f}" }'
ruby -Itest test/protocol_test.rb
```

368 tests, green on Ruby 2.7.8, 3.2.2 and 3.3.0. Lint with `rubocop` (Lint cops only, target Ruby 2.7). The `http_server_test` socket tests are timing sensitive and occasionally flake on 3.2.2 and 3.3.0; rerun before treating them as a regression.

Live checks need SketchUp running with the extension loaded. They write only under `~/sk-mcp-scratch/`.

| Command | What |
|---|---|
| `bin/sk-mcp-ensure` | Python 3. Starts SketchUp if `/health` does not answer and waits up to 60 s. Env: `SK_RUBY_MCP_PORT`, `SK_RUBY_MCP_WAIT_S`, `SKETCHUP_YEAR`. |
| `ruby eval/protocol_smoke.rb` | Handshake, `tools/list`, `model_status`, `/health`, 405 and Origin checks. |
| `ruby eval/save_look.rb [view] [out.jpg]` | Live `model_look`: JSON on stdout, JPEG on disk. |
| `ruby eval/soak.rb` | Twenty document operations in a row: new, draw, save_as, switch, copy, close, revert, discard. Fails on any new SketchUp crash report. |
| `ruby eval/blind_tester.rb --provider openai\|anthropic --base-url URL --model NAME` | Runs the three architect jobs in `eval/jobs/` through an LLM that sees only `tools/list`. API key from `$OPENAI_API_KEY` or the variable named by `SK_MCP_LLM_KEY_ENV`. Transcripts go to `eval/runs/`. |

`SK_RUBY_MCP_HOST` and `SK_RUBY_MCP_PORT` override the target for all eval scripts.

## Layout

```
sk_ruby_mcp.rb          extension registration
sk_ruby_mcp/
  main.rb               composition root, auto-start, app observer
  settings.rb           read_default / write_default
  settings_ui.rb        Plugins menu and native settings dialog
  protocol/             JSON-RPC parsing, MCP methods, howto resource
  transport/            HTTP server and pump, router, loopback guard, /mcp endpoint
  runtime/              document session, save policy, skp header, path identity, Ruby executor, viewport capture,
                        scene_geometry mixin, architect ops, facade math / scene / ops / capture
  tools/                document tools, model_look, execute_ruby, architect_pack, facade_pack
  assets/blank.skp      fallback blank for model_new
test/                   minitest, no SketchUp required
eval/                   live checks against a running SketchUp
bin/                    sk-mcp-test, sk-mcp-ensure, sk-facade-resolve
```

## Roadmap and non-goals

Later: named architect tools (wall, slab, window) as modules on the same server, Windows verification. `execute_ruby` stays as the escape hatch.

Never: a modelling UI or toolbar inside SketchUp; a second process to keep alive; SketchUp Web or iPad. The Plugins menu is only for running the server and editing settings.
