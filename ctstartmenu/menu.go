package main

import (
	"fmt"
	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
	"os"
	"strings"
	"time"
)

var (
	app          *tview.Application
	frame        *tview.Frame
	resultWriter *os.File
	hostname     string
)

func startMenu(opts *options) {
	// This is a fd of pipeWriter inherited from the supervisor
	resultWriter = os.NewFile(uintptr(3), "result")

	// tcell/terminfo requires TERM to be set, otherwise it tries to detect it
	// using infocmp, which is not available
	os.Setenv("TERM", "linux")

	if h, err := os.Hostname(); err == nil {
		hostname = h
	} else {
		hostname = "unknown host"
	}

	app = tview.NewApplication()
	pages := tview.NewPages()
	mainMenu := tview.NewList()
	commandField := tview.NewInputField()
	timeoutChannel := make(chan string, 1)
	initCommand := opts.args[0]

	timeoutRunning := true
	if opts.timeout == 0 {
		timeoutRunning = false
	}

	nixosMenu := tview.NewList()
	nixosGenerations := listNixosGenerations()

	mainMenu.
		AddItem("Start system", fmt.Sprintf("Executes %s", initCommand), 'i', func() {
			sendExec(opts.args)
		})

	if len(nixosGenerations) > 0 {
		mainMenu.AddItem("Select NixOS generation", "Start into older system version", 'g', func() {
			pages.SwitchToPage("nixosMenu")
			setFrameTextMenu()
		})
	}

	mainMenu.
		AddItem("Run shell", "Start /bin/sh", 's', func() {
			sendShell()
		}).
		AddItem("Run custom command", "Enter custom init command and arguments", 'c', func() {
			pages.SwitchToPage("customCommand")
			setFrameTextEditField()
		}).
		AddItem("Reboot", "Reboot the system", 'r', func() {
			sendReboot()
		}).
		SetChangedFunc(func(int, string, string, rune) {
			if timeoutRunning {
				timeoutChannel <- "stop"
				timeoutRunning = false
			}
		})

	if len(nixosGenerations) > 0 {
		makeNixosMenu(nixosMenu, nixosGenerations).
			SetDoneFunc(func() {
				pages.SwitchToPage("mainMenu")
				setFrameTextNoTimeout()
			})
	}

	commandField.
		SetLabel("Run command: ").
		SetText(strings.Join(opts.args, " ")).
		SetDoneFunc(func(key tcell.Key) {
			if key == tcell.KeyEscape {
				pages.SwitchToPage("mainMenu")
				setFrameTextNoTimeout()
				return
			}

			sendExec(strings.Fields(commandField.GetText()))
		})

	pages.AddPage("mainMenu", mainMenu, true, true)
	pages.AddPage("nixosMenu", nixosMenu, true, false)
	pages.AddPage("customCommand", commandField, true, false)

	frame = tview.NewFrame(pages).
		SetBorders(2, 2, 2, 2, 4, 4)

	if opts.timeout > 0 {
		go timeoutRoutine(opts.timeout, timeoutChannel, opts.args)
	} else {
		setFrameTextNoTimeout()
	}

	if err := app.SetRoot(frame, true).SetFocus(frame).Run(); err != nil {
		panic(err)
	}
}

func addDefaultFrameText() *tview.Frame {
	frame.Clear()
	return frame.
		AddText("Start Menu", true, tview.AlignCenter, tcell.ColorWhite).
		AddText(hostname, true, tview.AlignCenter, tcell.ColorRed).
		AddText("Start Menu is a part of vpsAdminOS from vpsFree.cz", false, tview.AlignCenter, tcell.ColorGreen)
}

func setFrameTextTimeout(timeout uint) {
	addDefaultFrameText().
		AddText(fmt.Sprintf("Starting the system in %d...", timeout), false, tview.AlignCenter, tcell.ColorGreen)
}

func queueFrameTextTimeout(timeout uint) {
	app.QueueUpdateDraw(func() {
		setFrameTextTimeout(timeout)
	})
}

func setFrameTextNoTimeout() {
	addDefaultFrameText()
}

func queueFrameTextNoTimeout() {
	app.QueueUpdateDraw(setFrameTextNoTimeout)
}

func setFrameTextEditField() {
	addDefaultFrameText().
		AddText("ESC to return to the previous menu, ENTER to start the command", false, tview.AlignCenter, tcell.ColorGreen)
}

func setFrameTextMenu() {
	addDefaultFrameText().
		AddText("ESC to return to the previous menu, ENTER to start the selected system", false, tview.AlignCenter, tcell.ColorGreen)
}

func timeoutRoutine(timeout uint, c <-chan string, command []string) {
	queueFrameTextTimeout(timeout)

	for {
		if timeout == 0 {
			sendExec(command)
			return
		}

		select {
		case res := <-c:
			if res == "stop" {
				queueFrameTextNoTimeout()
				return
			} else {
				panic(fmt.Sprintf("unknown word '%s'", res))
			}
		case <-time.After(1 * time.Second):
			timeout -= 1
			queueFrameTextTimeout(timeout)
		}
	}
}
