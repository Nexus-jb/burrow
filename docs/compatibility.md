# Compatibility gate

Before anyone else is asked to use Burrow, 20 tweaks must work with it on a
real device, with Burrow as the tweak loader and as the hooking engine, and
none of them may crash under it.

## How it is checked

As root, `burrowctl tweaks` lists every tweak in
`/var/jb/usr/lib/TweakInject`:

- the package that installed it and the package's version;
- whether it links the hooking engine;
- what its filter is for;
- the running processes it is in;
- its crashes in the crash log, and how many came after Burrow's loader took
  over;
- where Safe Mode or the settings turned it off.

The last line counts them. A tweak whose processes are not running shows
"no running process": open what it is for, check that the tweak does its job
there, and run the command again.

A tweak can be a link to a library elsewhere, as `CepheiSpringBoard.dylib` is
a link to `Cephei.framework/Cephei`. A process maps the library under its own
path, so the command finds the tweak by that path. On Dopamine, packages list
their tweaks under `Library/MobileSubstrate/DynamicLibraries`, a link to
`usr/lib/TweakInject`, so the package of a tweak is found with the links
followed.

## Result

iPhone 14 Pro Max (A16), iOS 16.3.1, Dopamine, rootless. Burrow's loader
took over from ElleKit's at 2026-11-19 10:21, and Burrow's engine at about
11:44. Builds 0.0.0~dev.86 to 0.0.0~dev.92.

| Tweak | Package | Links the engine | Checked |
| ----- | ------- | ---------------- | ------- |
| AudioRecorder | net.limneos.audiorecorderxs-rootless 5.2-6 | yes | Running |
| AudioRecorderUI | net.limneos.audiorecorderxs-rootless 5.2-6 | yes | In SpringBoard |
| CameraModes | com.ps.cameramodes 1.2.2 | yes | Worked in Camera: the mode it was set to hide was gone |
| CarBridge | com.leftyfl1p.carbridge13 2.0.17 | yes | In SpringBoard |
| CCSupport | com.opa334.ccsupport 1.3.13.1 | yes | In SpringBoard |
| CepheiSpringBoard | ws.hbang.common 2.0 | no (a link to Cephei's library) | In SpringBoard |
| Cercube | com.cercube.ios 6.6.0 | no | Worked in YouTube |
| IconTweak2 | com.ichitaso.icontweak2 1.1.0 | yes | In SpringBoard |
| MessageDateTime | com.cydiageek.messagedatetime 1.0.1 | yes | Worked in Messages |
| PowerSelectorApp | com.ichitaso.powerselector11 1.5.1 | yes | Worked in the PowerSelector app |
| PowerSelectorOptions | com.ichitaso.powerselector11 1.5.1 | yes | In SpringBoard |
| PreferenceLoader | preferenceloader 2.2.8 | yes | In Settings, which showed the tweaks' settings |
| SandyProxy | com.opa334.libsandy 1.1.6-4 | yes | Running |
| SimpleActivationActions | net.limneos.simpleactivationactions-rootless 0.1-3 | yes | In SpringBoard |
| TWIGalaxy | com.den.twigalaxy 1.14-1+debug | yes | Worked in X |
| UltraHomeScreen | com.ultrateam.ultrahomescreen 1.7.2 | no | In SpringBoard |
| UltraMotion | com.ultrateam.ultramotion 1.0.0 | yes | In SpringBoard |
| UltraRec | com.ultrateam.ultrarec 2.4.1 | no | In replayd and SpringBoard |
| UltraRecBackTap | com.ultrateam.ultrarec 2.4.1 | no | In backboardd and AccessibilityUIServer |
| UltraThemes | com.ultrateam.ultrathemes 0.10.0~beta26 | yes | In about 90 processes, since its filter names UIKit |

The 20 tweaks come from 17 packages; 15 of them link the engine. None of
them crashed after Burrow's loader took over. UltraMotion's four
crashes in the crash log came at 05:29 and before, under ElleKit's loader,
from a bug since fixed in the tweak. `BurrowCrashProbe`, from the
`burrow-tests` package, is not counted: it crashes on purpose, in Safe
Mode's device test.
