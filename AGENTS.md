# IOS Simulator Test
* always test ios implementation to validate the UI/UX
* use cli xcodebuildmcp to test IOS app
* how to use xcodebuildmcp: xcodebuildmcp -h
* when simulator testing is needed and some iPhone simulators are already Booted, use `xcodebuildmcp simulator list` to pick another supported iPhone that is still `Shutdown`, then pass `--simulator-id` or `--simulator-name` explicitly so xcodebuildmcp boots and runs on that device instead of reusing an already started iPhone