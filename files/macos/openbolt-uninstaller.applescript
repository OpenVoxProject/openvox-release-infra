use framework "Foundation"
use framework "AppKit"
use scripting additions

on run
	try
		set scriptPath to POSIX path of (path to resource "openbolt-uninstaller.tool")
		set cmd to "/bin/bash " & quoted form of scriptPath & " 2>&1"
		set output to do shell script cmd with administrator privileges
		my showOutputWindow("Uninstall successful", output)
	on error errMsg number errNum
		my showOutputWindow("Uninstall failed (" & errNum & ")", errMsg as text)
	end try
end run

on showOutputWindow(titleText, bodyText)
    set bundle to current application's NSBundle's mainBundle()
	set iconPath to bundle's pathForResource_ofType_("openvox", "png")
	set winIcon to current application's NSImage's alloc()'s initWithContentsOfFile_(iconPath)

	set alert to current application's NSAlert's alloc()'s init()
	alert's setMessageText:titleText
	alert's addButtonWithTitle:"OK"
	alert's addButtonWithTitle:"Save Log…"
    alert's setIcon_(winIcon)

	set scrollRect to current application's NSMakeRect(0, 0, 620, 360)
	set textRect to current application's NSMakeRect(0, 0, 600, 340)
	set scrollView to (current application's NSScrollView's alloc()'s initWithFrame:scrollRect)
	(scrollView's setHasVerticalScroller:true)
	set textView to (current application's NSTextView's alloc()'s initWithFrame:textRect)
	(textView's setEditable:false)
	(textView's setString:bodyText)
	(scrollView's setDocumentView:textView)
	(alert's setAccessoryView:scrollView)

	set response to alert's runModal()
	if (response = (current application's NSAlertSecondButtonReturn)) then
		set savePanel to current application's NSSavePanel's savePanel()
		savePanel's setNameFieldStringValue:"openbolt-uninstall.log"
		if ((savePanel's runModal()) = (current application's NSModalResponseOK)) then
			set saveURL to savePanel's |URL|()
			set nsstr to current application's NSString's stringWithString:bodyText
			set errRef to reference
			set ok to (nsstr's writeToURL_atomically_encoding_error_(saveURL, true, (current application's NSUTF8StringEncoding), missing value))
			if (ok as boolean) is false then
				display dialog "Could not save log." buttons {"OK"} default button 1 with icon stop
			end if
		end if
	end if
end showOutputWindow
