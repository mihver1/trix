package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"trix/examples/bots/go/trixbot"
)

type textMessage struct {
	ChatID          string `json:"chat_id"`
	SenderAccountID string `json:"sender_account_id"`
	Text            string `json:"text"`
}

type fileMessage struct {
	ChatID          string  `json:"chat_id"`
	MessageID       string  `json:"message_id"`
	SenderAccountID string  `json:"sender_account_id"`
	FileName        *string `json:"file_name"`
}

type botError struct {
	Message string `json:"message"`
}

type connectionChanged struct {
	Connected bool   `json:"connected"`
	Mode      string `json:"mode"`
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	client, err := trixbot.NewClient(ctx, commandFromEnv(os.Getenv("TRIX_BOTD_CMD")))
	if err != nil {
		return err
	}
	defer client.Close()

	handle := optionalString(os.Getenv("TRIX_BOT_HANDLE"))
	masterSecretEnv := optionalString(os.Getenv("TRIX_BOT_MASTER_SECRET_ENV"))
	serverURL, err := requiredEnv("TRIX_SERVER_URL")
	if err != nil {
		return err
	}
	stateDir, err := requiredEnv("TRIX_BOT_STATE_DIR")
	if err != nil {
		return err
	}
	downloadsDir := filepath.Join(stateDir, "downloads")
	identity, err := client.Init(ctx, trixbot.InitParams{
		ServerURL:         serverURL,
		StateDir:          stateDir,
		ProfileName:       envOrDefault("TRIX_BOT_PROFILE_NAME", "Go Echo Bot"),
		Handle:            handle,
		MasterSecretEnv:   masterSecretEnv,
		PlaintextDevStore: envFlag("TRIX_BOT_PLAINTEXT_STORE"),
	})
	if err != nil {
		return err
	}

	if err := client.Start(ctx); err != nil {
		return err
	}

	for {
		select {
		case <-ctx.Done():
			_ = client.Stop(context.Background())
			return nil
		case notification, ok := <-client.Notifications():
			if !ok {
				return nil
			}
			switch notification.Method {
			case "bot.v1.text_message":
				var message textMessage
				if err := json.Unmarshal(notification.Params, &message); err != nil {
					return err
				}
				if message.SenderAccountID == identity.AccountID {
					continue
				}
				if _, err := client.SendText(ctx, message.ChatID, "echo: "+message.Text); err != nil {
					return err
				}
			case "bot.v1.file_message":
				var message fileMessage
				if err := json.Unmarshal(notification.Params, &message); err != nil {
					return err
				}
				if message.SenderAccountID == identity.AccountID {
					continue
				}
				if err := os.MkdirAll(downloadsDir, 0o755); err != nil {
					return err
				}
				target := filepath.Join(downloadsDir, downloadName(message.MessageID, message.FileName))
				if _, err := client.DownloadFile(ctx, message.ChatID, message.MessageID, target); err != nil {
					return err
				}
				if _, err := client.SendText(ctx, message.ChatID, "saved file: "+filepath.Base(target)); err != nil {
					return err
				}
			case "bot.v1.error":
				var event botError
				if err := json.Unmarshal(notification.Params, &event); err != nil {
					return err
				}
				fmt.Fprintf(os.Stderr, "bot error: %s\n", event.Message)
			case "bot.v1.connection_changed":
				var event connectionChanged
				if err := json.Unmarshal(notification.Params, &event); err != nil {
					return err
				}
				fmt.Fprintf(os.Stderr, "connection_changed connected=%t mode=%s\n", event.Connected, event.Mode)
			}
		}
	}
}

func requiredEnv(name string) (string, error) {
	value := os.Getenv(name)
	if value == "" {
		return "", fmt.Errorf("missing required environment variable %s", name)
	}
	return value, nil
}

func envOrDefault(name, fallback string) string {
	value := os.Getenv(name)
	if value == "" {
		return fallback
	}
	return value
}

func downloadName(messageID string, fileName *string) string {
	name := "attachment.bin"
	if fileName != nil && *fileName != "" {
		name = filepath.Base(*fileName)
	}
	return messageID + "-" + name
}

func envFlag(name string) bool {
	switch strings.ToLower(os.Getenv(name)) {
	case "1", "true", "yes":
		return true
	default:
		return false
	}
}

func optionalString(value string) *string {
	if value == "" {
		return nil
	}
	return &value
}

func commandFromEnv(value string) []string {
	if value == "" {
		return nil
	}
	return strings.Fields(value)
}
