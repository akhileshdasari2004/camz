# Install Cam Z on your iPhone

Status: the app compiles and its tests pass in CI for the iOS simulator. CI also produces an **unsigned** device archive (`CamZ-device-UNSIGNED.xcarchive.zip`) and an unsigned simulator app. Neither can be installed on an iPhone as it is. A signed install needs full Xcode, your Apple ID and your iPhone connected to your Mac. The steps below do that.

## What you need

- A Mac with **full Xcode** installed from the App Store. Command Line Tools alone are not enough.
- Your Apple ID added to Xcode: Xcode → Settings → Accounts → **+** → Apple ID. A free Apple ID can install the app on your own iPhone, but apps signed with it expire after seven days.
- An iPhone running iOS 17 or later, connected to the Mac with a cable.
- Homebrew, for XcodeGen: `brew install xcodegen`.

## Steps

1. Generate the Xcode project from the working copy, which includes the device diagnostics:

   ```bash
   brew install xcodegen
   cd "/Users/akhildasari/Downloads/ai cam"
   xcodegen generate
   open CamZ.xcodeproj
   ```

   The same steps work from a fresh clone of `https://github.com/akhileshdasari2004/camz.git`. Until the latest changes are pushed, the clone does not include the device diagnostics.

2. In Xcode, select the **CamZ** target → **Signing & Capabilities** → tick **Automatically manage signing** → choose your team. For a free Apple ID, pick the entry labelled "(Personal Team)".
   - Do not choose any other team. The project pins none, so your choice is stored in your Xcode settings, not in the repository.
   - The bundle identifier is `com.akhilesh.camz`. If Xcode says it is unavailable for your account, change `PRODUCT_BUNDLE_IDENTIFIER` and `bundleIdPrefix` in `project.yml` to an identifier you control, then run `xcodegen generate` again.

3. On the iPhone, turn on **Developer Mode**: Settings → Privacy & Security → Developer Mode → On. The phone restarts. Confirm after it restarts.

4. Connect the iPhone to the Mac, unlock it, and tap **Trust** if asked.

5. In Xcode's toolbar, choose your iPhone as the run destination, then press **Run** (⌘R). Xcode builds, signs and installs the app.

6. If the phone shows "Untrusted Developer", go to Settings → General → VPN & Device Management, select your Apple ID, and tap **Trust**. Then open Cam Z.

7. Allow **camera** access on first launch. Allow **adding photos** when you save the first photo.

Because Run builds the Debug configuration, the device diagnostics are active. Watch the Xcode console and filter for `camz`.

## If something fails

| Symptom | Fix |
| --- | --- |
| No team available | Add your Apple ID in Xcode → Settings → Accounts. |
| Bundle identifier unavailable | Change the identifier in `project.yml` as in step 2, then regenerate. |
| Developer Mode required | Step 3. |
| Signing error after a change | Product → Clean Build Folder (⇧⌘K), then Run again. |
| App stops opening after seven days | Free Apple ID builds expire. Repeat step 5. |

Keep your Apple ID password in Xcode. Do not share certificates or provisioning profiles.
