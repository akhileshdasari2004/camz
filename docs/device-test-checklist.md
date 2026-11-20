# Cam Z real-device test checklist

Run every test on your own iPhone and fill in the result column yourself. Leave a row blank until you have tested it. Do not record a result you have not seen.

## Test environment

- iPhone model: ____________
- iOS version: ____________
- Build: working copy or commit: ____________
- Date and time: ____________

## How to read the device log

Run from Xcode, then filter the console for `camz`. Each analysed frame prints one line:

`scene=… light=… exposure=… delta=… bias=… zoom=… focus=x,y readiness=… guidance=… faces=…`

- `scene` ends in `?` when the scene is a low-confidence guess. A guess never moves the lens.
- `delta` is the EV change the AI suggests. `bias` is the EV currently applied.
- `focus` is the autofocus target in normalised image coordinates, origin bottom-left.

Each shutter press prints `capture waited=…s outcome=saved` or `outcome=failed`.

The log contains labels and numbers only. It has no photos, metadata or network traffic.

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
| 9 | Manual override | Drag the EV slider. Switch to Pro, then back to Auto. | `bias` follows your slider and the AI stops changing it. Pro prints no decision lines. Auto resumes. | | |
| 10 | Tap to focus | Tap a subject. Watch `focus=` for about four seconds. | Focus moves to the tap. AI tracking pauses for about four seconds. | | |
| 11 | Subject tracking | Move a face slowly, then leave it still. | `focus=` updates only when the subject moves about 8%. No hunting. | | |
| 12 | Guidance | Tilt the phone. Put a subject at the edge. Shrink the subject. Centre a good shot. Move quickly. | "Level your phone", "Move slightly left/right", "Move closer", "Great framing", "Hold steady". One message at a time. | | |
| 13 | Capture latency | Film the shutter press with a stopwatch, and read `waited=`. Repeat in Apple Camera. | `waited` is at most 1.5 s. Report the measured delay for both apps. | | |
| 14 | Photo saving | Take a photo. Open it from the thumbnail. Check its Info panel. | The photo appears in Photos with the right orientation, date and lens data. The Original look keeps the camera's own file. | | |
| 15 | Photos denied | Deny adding photos, then take a photo. | Toast: "Allow Cam Z to add photos…". Capture still works. | | |
| 16 | Interruptions | Start a call or open another camera app. Background the app and come back. | "Camera paused" appears, then the preview recovers. | | |
| 17 | Thermal and battery | Use the app continuously for ten minutes. | Note warmth and battery drop. Decision lines stop when the app is backgrounded. | | |
| 18 | Image quality comparison | Photograph the same scenes with Apple Camera. Compare sharpness, noise, colour and highlights. | Only after this comparison may you judge quality. Do not claim Cam Z beats Apple Camera without it. | | |

## Stop and report if

- The app crashes, or the preview freezes.
- Photos fail to save, or saved orientation is wrong.
- Exposure flickers back and forth.
- A capture takes longer than about 1.5 s.
