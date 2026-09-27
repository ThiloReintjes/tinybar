# Subar

A macOS menu bar app that shows how much of each AI coding subscription is used up, how many tokens were used over time, and what that usage would have cost at API prices.

## Language

### Subscriptions and limits

**Provider**:
A company whose AI subscription Subar tracks (e.g. Anthropic via Claude, OpenAI via Codex, Google via Gemini, Anysphere via Cursor).
_Avoid_: Service, vendor, integration

**Limit Window**:
A rolling or fixed period in which a Provider caps usage, shown as the percentage left (100% at the start of the window, 0% when the cap is reached) and a Reset time (e.g. the 5-hour session window, the weekly window, a model-specific weekly window).
_Avoid_: Quota, rate limit, bucket

**Reset**:
The moment a Limit Window's usage returns to zero.
_Avoid_: Renewal, refresh

**Banked Reset**:
A saved Codex reset coupon the user holds, which can be redeemed to reset a Limit Window early. Subar only displays it and never redeems it.
_Avoid_: Reset credit, rollover

**Pinned Limit**:
The single Limit Window the user picked in the popover to show in the menu bar.
_Avoid_: Primary limit, featured limit

**Limit Alert**:
A macOS notification sent when a 5-hour or weekly Limit Window crosses 90% or 95% used, or when it Resets after having crossed 90%.
_Avoid_: Warning, reminder

**Stale**:
The state of a Provider whose latest data could not be fetched (e.g. an expired login). Its last known values are shown with the time they were fetched.
_Avoid_: Offline, error state

### Token history

**Usage Record**:
A single model response from a local coding CLI log, with its token counts (input, output, cache write, cache read), model, timestamp and Project.
_Avoid_: Event, entry, log line

**Project**:
The code repository a Usage Record was produced in, identified by the git repository that contains the working directory.
_Avoid_: Workspace, folder, cwd

**Provisional Day**:
A local calendar day whose totals may still grow because CLI logs are written late. A day becomes final one hour after its midnight.
_Avoid_: Open day, pending day

**Theoretical Cost**:
What a set of Usage Records would have cost at the Provider's public API prices. It is not what the user actually paid.
_Avoid_: Spend, cost, bill
