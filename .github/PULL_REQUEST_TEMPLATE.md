Closes #

## What changed

<!-- What it does and how. Call out anything non-obvious, surprising, or a trade-off you made on purpose. -->

## Performance

<!-- After a few minutes idle:
     pid=$(pgrep -x Tinybar); ps -o %cpu=,rss=,time= -p $pid; footprint $pid | grep Footprint -->

| | Before | After |
| --- | --- | --- |
| Idle CPU | | |
| Footprint | | |

## Screenshots

<!-- Visual change: before and after, light and dark.
     `.build/debug/Tinybar --snapshot out.png --redact-projects` renders both.
     Delete this section if nothing visual changed. -->

## Testing

<!-- What you ran and what you did by hand, including after a restart.
     Log parsing changes: the independent count you checked against. -->

- [ ] `swift test` passes and `./Scripts/build-app.sh` builds
- [ ] Used the app with this change
- [ ] SPEC.md, CONTEXT.md and README.md still match
