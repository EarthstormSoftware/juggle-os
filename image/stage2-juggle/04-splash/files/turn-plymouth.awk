# The Plymouth theme on its input, for a display turned clockwise by r degrees (90, 180, 270; run with -v r=): the
# pictures are turned to suit (by the build), so what's left is where each one sits on the screen.
/HorizontalAlignment=/ { split($0, h, "="); next }
/VerticalAlignment=/ {
	split($0, v, "=")
	x = h[2] + 0
	y = v[2] + 0
	if (r == 90) { across = 1 - y; down = x }
	else if (r == 180) { across = 1 - x; down = 1 - y }
	else { across = y; down = 1 - x }
	print h[1] "=" across
	print v[1] "=" down
	next
}
/^ImageDir=/ { print $0 "-" r; next }
/^Name=/ { print $0 ", turned " r; next }
{ print }
