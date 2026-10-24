# Uninstallation Guide - Gaming Performance Suite

## Safe Uninstall (Recommended)
1. **Stop everything**: Run `Stop-GamingSuite.bat` as Administrator - this restores all journaled settings
2. **Remove from startup** (if added): Remove "Gaming Performance Suite Watcher" from `shell:startup`
3. **Delete installation folder**: Remove the entire suite folder
4. **Remove shortcuts**: Delete from Start Menu and Desktop
5. **Optional**: Remove any virtual audio drivers installed by your microphone companion tool
6. **Optional**: Delete "Gaming Performance Suite" power plan from Power Options if present

## Automatic Uninstall
If installed via the setup package, use Windows Settings > Apps > Gaming Performance Suite > Uninstall, or Control Panel > Programs and Features.

## What Gets Removed
- Only files/folders created by the installation
- Registry startup entry (if added via installer)
- Shortcuts

## What is NOT Touched
- No system services created by this suite
- No kernel drivers installed by this suite (only uses existing Windows drivers)
- No scheduled tasks created by this suite
- Game files or user data outside the installation directory
- Windows system files

## Verification
After uninstall, check:
- No processes named related to the suite running
- No entries in `shell:startup` or Task Manager > Startup
- Installation directory removed
