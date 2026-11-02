# Video-control synchronization regression

The user reported that Baidu results felt less smooth after the eD2K/size/form build. The web-specific changes in that build were Bilibili universal-link confirmation, eD2K/thunder navigation entry points, and video-control scale calculation. Baidu result styling, filtering rules and native Back/Forward were not changed in that build.

Inspection found an unbounded path: each `visualViewport.resize` message caused native scale synchronization across all registered media frames, even if scale had not changed. Each receiving video runtime scheduled layout again. The new direct native scale read removed the previous asynchronous read before that fan-out, without deduplicating unchanged values. This is an avoidable source of work; it has not been measured as the sole cause of the user's perceived regression.

The follow-up is limited to three existing files:

- Viewport resizing schedules local control layout without sending a native scale message. Actual native zoom callbacks, page-zoom changes and frame readiness already cover scale initialization and updates.
- Native full-frame broadcasts are deduplicated by navigation generation and scale/zoom values. Explicit initialization of a ready/restored frame is preserved.
- The JavaScript setters report whether state changed. Repeated identical values do not schedule another control layout. The native value still overrides stale cached viewport scale during restoration.

Read-only phone state showed Baidu optimization disabled and both eD2K and BT records paused. Only download transport/status counts and relevant boolean flags were examined; no file names or browsing contents were printed.

Validation: 1,000 unchanged JavaScript updates returned no change; real/invalid scale behavior and script syntax passed. Source checks confirm the viewport-to-native resize message is removed. Native Back/Forward and Bilibili confirmation remain untouched. No automated device browsing or new Safari benchmark was run; actual smoothness remains for the user's manual comparison.

The Release follow-up compiled, passed code-signature verification, and was installed/launched normally on the iPhone at 20:31 on 2026-11-01.
