package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/creack/pty"
	"github.com/gdamore/tcell/v2"
	"github.com/rivo/tview"
	"golang.org/x/sys/unix"
	"os"
	"os/exec"
	"strings"
	"time"
)

type options struct {
	timeout  uint
	ui       bool
	preserve bool
	reboot   bool
	args     []string
}

type startCommand struct {
	Action string
	Args   []string
}

var (
	app          *tview.Application
	frame        *tview.Frame
	resultWriter *os.File
	hostname     string
)

func main() {
	opts := parseOptions()
	if opts == nil {
		return
	}

	if opts.ui {
		startMenu(opts)
		return
	}

	if opts.reboot {
		unix.Reboot(unix.LINUX_REBOOT_CMD_RESTART)
		return
	}

	supervisor(opts)
}

func parseOptions() *options {
	opts := &options{}

	flag.Usage = func() {
		fmt.Fprintf(
			flag.CommandLine.Output(),
			"Usage:\n  %s [options] <init command...>\n\nOptions:\n", os.Args[0],
		)
		flag.PrintDefaults()
	}

	flag.UintVar(
		&opts.timeout,
		"timeout",
		5,
		"Number of seconds after which the system is started automatically",
	)

	flag.BoolVar(
		&opts.ui,
		"ui",
		false,
		"Used internally by ctstartmenu",
	)

	flag.BoolVar(
		&opts.preserve,
		"preserve",
		false,
		"Do not delete self",
	)

	flag.BoolVar(
		&opts.reboot,
		"reboot",
		false,
		"Reboot the system",
	)

	flag.Parse()

	args := flag.Args()

	if len(args) < 1 {
		fmt.Fprintf(os.Stderr, "Error: missing init command\n")
		flag.Usage()
		return nil
	}

	opts.args = args

	return opts
}

func supervisor(opts *options) {
	pipeReader, pipeWriter, err := os.Pipe()
	if err != nil {
		panic(err)
	}

	defer pipeReader.Close()

	args := []string{"-ui", "-timeout", fmt.Sprint(opts.timeout)}

	if opts.preserve {
		args = append(args, "-preserve")
	}

	cmd := exec.Command(os.Args[0], append(args, opts.args...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = []*os.File{pipeWriter}

	if _, err := pty.Start(cmd); err != nil {
		panic(err)
	}

	pipeWriter.Close()
	buffer := new(bytes.Buffer)

	if _, err := buffer.ReadFrom(pipeReader); err != nil {
		panic(err)
	}

	if err := cmd.Wait(); err != nil {
		panic(err)
	}

	data := startCommand{}

	if err := json.Unmarshal(buffer.Bytes(), &data); err != nil {
		panic(err)
	}

	// Delete self in case we still exist
	if !opts.preserve {
		os.Remove(os.Args[0])
	}

	if data.Action == "exec" {
		if err = unix.Exec(data.Args[0], data.Args, os.Environ()); err != nil {
			panic(err)
		}
	} else if data.Action == "reboot" {
		reboot := exec.Command(os.Args[0], "-reboot", "_reboot")
		reboot.Stdin = os.Stdin
		reboot.Stdout = os.Stdout
		reboot.Stderr = os.Stderr

		if err := reboot.Run(); err != nil {
			panic(err)
		}
	} else {
		panic(fmt.Sprintf("unknown action '%s'", data.Action))
	}
}

func startMenu(opts *options) {
	// Delete self
	if !opts.preserve {
		os.Remove(os.Args[0])
	}

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
	timeoutRunning := true
	initCommand := opts.args[0]

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
			sendExec([]string{"/bin/sh"})
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

	go timeoutRoutine(opts.timeout, timeoutChannel, opts.args)

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

func sendExec(command []string) {
	sendResult(&startCommand{Action: "exec", Args: command})
}

func sendReboot() {
	sendResult(&startCommand{Action: "reboot"})
}

func sendResult(command *startCommand) {
	data, err := json.Marshal(command)
	if err != nil {
		panic(err)
	}

	resultWriter.Write(data)
	resultWriter.Close()
	app.Stop()
}
