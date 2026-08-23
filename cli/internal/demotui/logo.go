package demotui

// logoFrames is the animated EterDB mark for the intro/loading screen: the
// brand roundel (a thick ring with a rewind needle sweeping counter-clockwise,
// the undo direction), rasterized to braille. Every frame is the same size so
// the loop stays put; cycled a frame at a time and tinted green in the intro
// scene. Regenerate with scratch/genlogo.py if the logo changes.
//
// The ring spans FIVE braille rows (20 dot-rows) and is sized so the bottom-most
// dot-row (braille dots 7,8) is always empty. Those dots render on the very
// floor of the character cell and many terminals clip them, which cut off the
// ring's bottom arc (issue #179). Keep that empty last dot-row when regenerating.
var logoFrames = [][]string{
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⠀⠉⠻⣿⡄", "⢸⣿⠿⠿⠿⠿⠿⣿⡇", "⠈⢿⣷⣤⣀⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⠀⠉⣻⣿⡄", "⢸⣿⣴⠶⠞⠛⠋⣿⡇", "⠈⢿⣷⣤⣀⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⠀⣉⣿⣿⡄", "⢸⣿⣠⣴⠞⠋⠁⣿⡇", "⠈⢿⣿⣤⣀⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⠀⣩⠿⣿⡄", "⢸⣿⠀⣠⠞⠁⠀⣿⡇", "⠈⢿⣿⣥⣀⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⢠⡿⠻⣿⡄", "⢸⣿⠀⢠⡿⠁⠀⣿⡇", "⠈⢿⣷⣿⣁⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⣸⡏⠻⣿⡄", "⢸⣿⠀⢀⣿⠀⠀⣿⡇", "⠈⢿⣷⣼⣇⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⠉⣿⠉⠻⣿⡄", "⢸⣿⠀⠀⣿⠀⠀⣿⡇", "⠈⢿⣷⣤⣿⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⢹⣇⠉⠻⣿⡄", "⢸⣿⠀⠀⣿⡀⠀⣿⡇", "⠈⢿⣷⣤⣸⣧⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠟⢿⡄⠉⠻⣿⡄", "⢸⣿⠀⠈⢿⡄⠀⣿⡇", "⠈⢿⣷⣤⣈⣿⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⠿⣍⠀⠉⠻⣿⡄", "⢸⣿⠀⠈⠳⣄⠀⣿⡇", "⠈⢿⣷⣤⣀⣬⣿⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⣿⣉⠀⠉⠻⣿⡄", "⢸⣿⠈⠙⠳⣦⣄⣿⡇", "⠈⢿⣷⣤⣀⣤⣿⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
	{"⠀⢀⣤⣴⣶⣦⣤⡀⠀", "⢠⣿⣟⠉⠀⠉⠻⣿⡄", "⢸⣿⠙⠛⠳⠶⣦⣿⡇", "⠈⢿⣷⣤⣀⣤⣾⡿⠁", "⠀⠀⠉⠙⠛⠋⠉⠀⠀"},
}
