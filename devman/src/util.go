package main

import "fmt"

func hexToByte(s string) (byte, error) {
	var b byte
	for i := 0; i < 2; i++ {
		var v byte
		switch {
		case s[i] >= '0' && s[i] <= '9':
			v = s[i] - '0'
		case s[i] >= 'a' && s[i] <= 'f':
			v = s[i] - 'a' + 10
		case s[i] >= 'A' && s[i] <= 'F':
			v = s[i] - 'A' + 10
		default:
			return 0, fmt.Errorf("invalid hex")
		}
		b = b<<4 | v
	}
	return b, nil
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
