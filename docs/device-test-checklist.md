# Cam Z real-device test checklist

Run every test on your own iPhone and fill in the result column yourself. Leave a row blank until you have tested it. Do not record a result you have not seen.

## Test environment

- iPhone model: ____________
- iOS version: ____________
- Build: working copy or commit: ____________
- Date and time: ____________

## How to read the device log

Run from Xcode, then filter the console for `camz`. Each analysed frame prints one line:

`scene=… light=… source=… exposure=… delta=… bias=… zoom=… blur=… focus=x,y readiness=… guidance=… faces=…`

- `scene` ends in `?` when the scene is a low-confidence guess. A guess never moves the lens.
- `delta` is the EV change the AI suggests. `bias` is the EV currently applied.
- `focus` is the autofocus target in normalised image coordinates, origin bottom-left.
- `source` is the light inferred from the colour cast. It is a heuristic. White balance is never locked: locking is off.
- `blur` is the handheld blur risk from the exposure time and the lens: low, medium, high, or unknown.

Each shutter press prints `capture waited=…s outcome=saved` or `outcome=failed`. Hands-free prints `handsfree capture` when it fires. Best of three prints `bestof3 sharpness=[…] chosen=… eyesOpen=…`, with one score per shot, the shot kept, and whether its eyes were open.

The log contains labels and numbers only. It has no photos, metadata or network traffic.

## Pro setup before testing Pro features

1. Create the monthly and annual auto-renewing subscriptions in App Store Connect, or in a StoreKit configuration file in Xcode for local tests.
2. Enter their product IDs in `CamZ/Info.plist` (`CamZProMonthlyProductID`, `CamZProAnnualProductID`) and in `project.yml`, so XcodeGen keeps them. Empty IDs mean Pro is not set up in this build.
3. Sign in to a sandbox tester in Settings > App Store before buying on the device.

Until these steps are done, rows 25 to 28 cannot be run. Leave them blank.

## Tests

| # | Scenario | How to test | Expected | Result | Log notes |
| --- | --- | --- | --- | --- | --- |
| 1 | Permissions | Deny camera on first launch, then allow in Settings. | Denied shows the permission screen with an Open Settings button. Allowing starts the preview. | | |
| 2 | Live preview | Watch the preview for a minute, then rotate the phone. | Smooth preview with no freezes. The UI stays in portrait. | | |
| 3 | Daylight outdoors | Point at a sky and a shaded subject. | Sky not blown out. `light=` reads Good light or Bright, and `delta` stays small. | | |
| 4 | Portrait | One person, close and far. | `scene=Portrait`. Skin not overexposed. `focus` follows the eyes. Zoom changes to 2× only when the face is small. | | |
| 5 | Indoor | Warm lamp light, and a mixed-light room. | No strong lifting, no hunting between values. | | |
| 6 | Backlit | Subject in front of a bright window. | `light=Backlit`. Report honestly whether the subject improved and whether the window clipped. | | |
| 7 | Low light and night | Dim room, then a night street. | `light=Low light`, `delta=0.00`. The photo keeps its night mood. Capture waits for more calm frames. | | |
| 8 | Zoom | Tap 0.5×, 1×, 2×, 3×, then pinch. | Smooth transitions. Auto changes zoom only for confident scenes. Nothing beyond 3× unless you pinch. | | |
| 9 | Manual override | Drag the EV slider. Switch to Pro (needs Cam Z Pro; a free user sees the paywall), then back to Auto. | `bias` follows your slider and the AI stops changing it. Pro prints no decision lines. Auto resumes. | | |
| 10 | Tap to focus | Tap a subject. Watch `focus=` for about four seconds. | Focus moves to the tap. AI tracking pauses for about four seconds. | | |
| 11 | Subject tracking | Move a face slowly, then leave it still. | `focus=` updates only when the subject moves about 8%. No hunting. | | |
| 12 | Guidance | Tilt the phone. Put a subject at the edge. Shrink the subject. Centre a good shot. Move quickly. | "Level the horizon", "Move slightly left/right", "Move closer", "Perfect framing", "Hold steady". One message at a time. "Perfect framing" means no framing rule fired. It is not a judgement of the photo. Rows 19 to 21 cover the other messages. | | |
| 13 | Capture latency | Film the shutter press with a stopwatch, and read `waited=`. Repeat in Apple Camera. | `waited` is at most 1.5 s. Report the measured delay for both apps. | | |
| 14 | Photo saving | Take a photo. Open it from the thumbnail. Check its Info panel. | The photo appears in Photos with the right orientation, date and lens data. The Original look keeps the camera's own file. | | |
| 15 | Photos denied | Deny adding photos, then take a photo. | Toast: "Allow Cam Z to add photos…". Capture still works. | | |
| 16 | Interruptions | Start a call or open another camera app. Background the app and come back. | "Camera paused" appears, then the preview recovers. | | |
| 17 | Thermal and battery | Use the app continuously for ten minutes. | Note warmth and battery drop. Decision lines stop when the app is backgrounded. | | |
| 18 | Image quality comparison | Photograph the same scenes with Apple Camera. Compare sharpness, noise, colour and highlights. | Only after this comparison may you judge quality. Do not claim Cam Z beats Apple Camera without it. | | |
| 19 | Hold steady at night | Night street, phone held in one hand with no support. Take one photo braced against a wall and one unbraced. | `blur=high` while the exposure is long. The guidance says "Hold steady" until the exposure is short enough for the lens. Compare the sharpness of the two photos. | | |
| 20 | Raise or lower the camera | Frame a subject high in the frame, then low, then cut off at the bottom. | "Raise your camera" when the subject sits high. "Lower your camera" when it sits low or is cut off at the bottom. Raising the phone moves the subject down in the frame. | | |
| 21 | Group framing | Three people, one at each edge, then all in the centre. | "Move slightly left" or "right" when someone is cut off. "Perfect framing" when everyone fits. No "Move closer" for a group. | | |
| 22 | Light source | Warm indoor lamp, window daylight, and fluorescent office light if you can find it. | `source=Warm indoor light`, `Daylight`, or `Fluorescent light`. Compare the colour of the photos with what you saw. | | |
| 23 | Focus release | Point at a subject, then move to an empty wall for three seconds. | `focus=` stops updating once the subject leaves. About two seconds later focus returns to the centre. | | |
| 24 | Free user gating | Without Pro, tap the Auto, hands-free and best-of-three buttons. | The paywall opens each time. Pro mode, hands-free and best of three do not start. Free features keep working. | | |
| 25 | Paywall prices | With product IDs configured, open the paywall. | Names, prices and periods come from the App Store, not from the app. With empty IDs it says Pro is not set up. | | |
| 26 | Purchase (sandbox) | Buy the monthly plan with a sandbox tester. | Pro features unlock and the paywall says Cam Z Pro is active. | | |
| 27 | Restore | Delete and reinstall, then tap Restore purchases on the same Apple ID. | Pro returns. A different Apple ID with no subscription says no active subscription was found. | | |
| 28 | Offline grace | After a confirmed purchase, turn on airplane mode and relaunch. | Pro still works offline. The 14-day limit is not tested here: it needs a 14-day wait, or a manual check of the code. | | |
| 29 | Hands-free | Pro user in Auto. Hold steady on a framed subject. | "Hands-free on · hold steady", then a 3, 2, 1 countdown, then one photo, then a short pause. Stop ends it at any time. At most five automatic photos per turn-on. | | |
| 30 | Hands-free in the background | Start a countdown, then switch apps. | No photo arrives after you return. Hands-free is off. | | |
| 31 | Heat pause | Run hands-free and best of three for ten minutes, or until the phone feels warm. | When the phone is hot, a toast says hands-free or best of three paused. The analysis slows. | | |
| 32 | Best of three | Pro user, flash off, steady subject. Press the shutter. | "Shot 1 of 3" to "Shot 3 of 3", then "Choosing the sharpest". One photo is added to Photos, and the toast says the others were discarded. Compare the saved photo with the two you did not keep, if you can see them. | | |
| 33 | Best of three with flash on | Turn the flash on, then press the shutter. | "Turn the flash off to use best of three." No photos are taken. | | |
| 34 | Best of three, eyes closed | Ask the subject to blink during the burst. | If every shot has closed eyes, the toast says no shot had open eyes. Record what happened. | | |

## Stop and report if

- The app crashes, or the preview freezes.
- Photos fail to save, or saved orientation is wrong.
- Exposure flickers back and forth.
- A capture takes longer than about 1.5 s.
- Hands-free fires without a countdown, or more than five times per turn-on.
- A free user reaches a Pro feature.
- The paywall shows a price that did not come from the App Store.
- Best of three saves a photo but does not say which of the three it kept.
