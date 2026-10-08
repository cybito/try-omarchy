on waitForInstallerFolder(installerWindow, mountedFolder)
  -- Finder may still be loading the new window's target. Keep every probe
  -- scoped to the window we created, regardless of other Finder activity.
  set expectedPath to POSIX path of mountedFolder
  set observedPath to "unavailable"
  repeat 50 times
    tell application "Finder"
      try
        set installerFolder to target of installerWindow
        set observedPath to POSIX path of (installerFolder as alias)
        if observedPath is expectedPath then return installerFolder
      end try
    end tell
    delay 0.2
  end repeat
  error "Finder did not open the mounted DMG folder within 10 seconds (expected " & expectedPath & ", got " & observedPath & ")"
end waitForInstallerFolder

on run arguments
  set mountPath to item 1 of arguments
  set appName to item 2 of arguments
  set mountedFolder to POSIX file mountPath as alias
  tell application "Finder"
    -- Creating our own window avoids reusing a tab or arranging whichever
    -- unrelated Finder window happens to be frontmost.
    set installerWindow to make new Finder window to mountedFolder
    set installerWindowID to id of installerWindow
    set installerWindow to Finder window id installerWindowID
    set installerFolder to my waitForInstallerFolder(installerWindow, mountedFolder)
    tell installerWindow
      set current view of installerWindow to icon view
      set toolbar visible of installerWindow to false
      set statusbar visible of installerWindow to false
      set pathbar visible of installerWindow to false
      set sidebar width of installerWindow to 0
      set bounds of installerWindow to {100, 100, 740, 540}

      set iconOptions to the icon view options of installerWindow
      set arrangement of iconOptions to not arranged
      set icon size of iconOptions to 128
      set text size of iconOptions to 14
      set shows icon preview of iconOptions to false

      set position of item appName of installerFolder to {180, 190}
      set position of item "Applications" of installerFolder to {460, 190}
    end tell
    update installerFolder without registering applications
    delay 2
    close installerWindow
  end tell
end run
