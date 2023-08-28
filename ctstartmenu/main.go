package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"github.com/creack/pty"
	"golang.org/x/sys/unix"
	"os"
	"os/exec"
	"os/signal"
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
	Action      string
	Args        []string
	Environment map[string]string
}

const (
	SIGRTMIN = unix.Signal(0x22)
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
	setupStopSignals()

	for {
		data, err := superviseMenu(opts)
		if err != nil {
			panic(err)
		}

		if data.Action == "exec" {
			// Delete self in case we still exist
			if !opts.preserve {
				os.Remove(os.Args[0])
			}

			env := os.Environ()

			for k, v := range data.Environment {
				env = append(env, fmt.Sprintf("%s=%s", k, v))
			}

			if err = unix.Exec(data.Args[0], data.Args, env); err != nil {
				panic(err)
			}
		} else if data.Action == "shell" {
			opts.timeout = 0 // in case we return to the menu
			superviseShell(data.Args)
		} else if data.Action == "reboot" {
			if err := doReboot(); err != nil {
				panic(err)
			}
		} else {
			panic(fmt.Sprintf("unknown action '%s'", data.Action))
		}
	}
}

func setupStopSignals() {
	halt := make(chan os.Signal, 1)

	// See lxc/src/lxc/lxccontainer.c for SIGRTMIN+3
	signal.Notify(halt, unix.SIGPWR, SIGRTMIN+3)

	go func() {
		<-halt
		os.Exit(0)
	}()

	reboot := make(chan os.Signal, 1)
	signal.Notify(reboot, unix.SIGINT)

	go func() {
		<-reboot
		doReboot()
	}()
}

func superviseMenu(opts *options) (*startCommand, error) {
	pipeReader, pipeWriter, err := os.Pipe()
	if err != nil {
		return nil, err
	}

	defer pipeReader.Close()
	args := []string{"-ui", "-timeout", fmt.Sprint(opts.timeout)}

	cmd := exec.Command(os.Args[0], append(args, opts.args...)...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.ExtraFiles = []*os.File{pipeWriter}

	if _, err := pty.Start(cmd); err != nil {
		return nil, err
	}

	pipeWriter.Close()
	buffer := new(bytes.Buffer)

	if _, err := buffer.ReadFrom(pipeReader); err != nil {
		return nil, err
	}

	if err := cmd.Wait(); err != nil {
		return nil, err
	}

	data := startCommand{}

	if err := json.Unmarshal(buffer.Bytes(), &data); err != nil {
		return nil, err
	}

	return &data, nil
}

func superviseShell(command []string) error {
	// Configure the supervisor process to perform a reboot on SIGTERM
	c := make(chan os.Signal, 1)
	signal.Notify(c, unix.SIGTERM)
	defer signal.Reset(unix.SIGTERM)

	go func() {
		<-c
		signal.Reset(unix.SIGTERM)
		if err := doReboot(); err != nil {
			panic(err)
		}
	}()

	time.Sleep(1 * time.Second)
	fmt.Print("This is an emergency shell launched by Start Menu.\n\n")
	fmt.Print("Exit the shell to return to the menu.\n\n")

	shell := exec.Command(command[0], command[1:]...)
	shell.Stdin = os.Stdin
	shell.Stdout = os.Stdout
	shell.Stderr = os.Stderr

	if _, err := pty.Start(shell); err != nil {
		return err
	}

	return shell.Wait()
}

func doReboot() error {
	reboot := exec.Command(os.Args[0], "-reboot", "_reboot")
	reboot.Stdin = os.Stdin
	reboot.Stdout = os.Stdout
	reboot.Stderr = os.Stderr

	return reboot.Run()
}

func sendExec(command []string) {
	sendResult(&startCommand{Action: "exec", Args: command})
}

func sendExecEnv(command []string, env map[string]string) {
	sendResult(&startCommand{Action: "exec", Args: command, Environment: env})
}

func sendShell() {
	sendResult(&startCommand{Action: "shell", Args: []string{"/bin/sh"}})
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
