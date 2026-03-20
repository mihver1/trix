package trixbot

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"
)

type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *RPCError) Error() string {
	return fmt.Sprintf("json-rpc error %d: %s", e.Code, e.Message)
}

type Notification struct {
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
}

type Client struct {
	cmd           *exec.Cmd
	stdin         io.WriteCloser
	notifications chan Notification
	pending       map[int64]chan rpcEnvelope
	mu            sync.Mutex
	nextID        int64
}

type InitParams struct {
	ServerURL         string  `json:"server_url"`
	StateDir          string  `json:"state_dir"`
	ProfileName       string  `json:"profile_name"`
	Handle            *string `json:"handle,omitempty"`
	MasterSecretEnv   *string `json:"master_secret_env,omitempty"`
	PlaintextDevStore bool    `json:"plaintext_dev_store"`
}

type Identity struct {
	AccountID         string  `json:"account_id"`
	DeviceID          string  `json:"device_id"`
	AccountSyncChatID string  `json:"account_sync_chat_id"`
	ServerURL         string  `json:"server_url"`
	ProfileName       string  `json:"profile_name"`
	Handle            *string `json:"handle"`
}

type SendTextResult struct {
	ChatID    string `json:"chat_id"`
	MessageID string `json:"message_id"`
	ServerSeq uint64 `json:"server_seq"`
}

type SendFileResult struct {
	ChatID             string `json:"chat_id"`
	MessageID          string `json:"message_id"`
	ServerSeq          uint64 `json:"server_seq"`
	BlobID             string `json:"blob_id"`
	PlaintextSizeBytes uint64 `json:"plaintext_size_bytes"`
	EncryptedSizeBytes uint64 `json:"encrypted_size_bytes"`
}

type DownloadFileResult struct {
	ChatID     string  `json:"chat_id"`
	MessageID  string  `json:"message_id"`
	BlobID     string  `json:"blob_id"`
	MimeType   string  `json:"mime_type"`
	FileName   *string `json:"file_name"`
	SizeBytes  uint64  `json:"size_bytes"`
	OutputPath string  `json:"output_path"`
}

type PublishKeyPackagesResult struct {
	Published int `json:"published"`
}

type rpcEnvelope struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      *int64          `json:"id,omitempty"`
	Method  string          `json:"method,omitempty"`
	Params  json.RawMessage `json:"params,omitempty"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   *RPCError       `json:"error,omitempty"`
}

func NewClient(ctx context.Context, command []string) (*Client, error) {
	if len(command) == 0 {
		command = []string{"cargo", "run", "-q", "-p", "trix-botd", "--", "stdio"}
	}

	cmd := exec.CommandContext(ctx, command[0], command[1:]...)
	cmd.Env = os.Environ()
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return nil, err
	}

	client := &Client{
		cmd:           cmd,
		stdin:         stdin,
		notifications: make(chan Notification, 64),
		pending:       make(map[int64]chan rpcEnvelope),
		nextID:        1,
	}
	go client.readLoop(stdout)
	return client, nil
}

func (c *Client) Notifications() <-chan Notification {
	return c.notifications
}

func (c *Client) Init(ctx context.Context, params InitParams) (Identity, error) {
	var out Identity
	err := c.request(ctx, "bot.v1.init", params, &out)
	return out, err
}

func (c *Client) Start(ctx context.Context) error {
	var out map[string]any
	return c.request(ctx, "bot.v1.start", map[string]any{}, &out)
}

func (c *Client) Stop(ctx context.Context) error {
	var out map[string]any
	return c.request(ctx, "bot.v1.stop", map[string]any{}, &out)
}

func (c *Client) ListChats(ctx context.Context) (map[string]any, error) {
	var out map[string]any
	err := c.request(ctx, "bot.v1.list_chats", map[string]any{}, &out)
	return out, err
}

func (c *Client) GetTimeline(ctx context.Context, chatID string, limit *int) (map[string]any, error) {
	var out map[string]any
	err := c.request(ctx, "bot.v1.get_timeline", map[string]any{
		"chat_id": chatID,
		"limit":   limit,
	}, &out)
	return out, err
}

func (c *Client) SendText(ctx context.Context, chatID, text string) (SendTextResult, error) {
	var out SendTextResult
	err := c.request(ctx, "bot.v1.send_text", map[string]any{
		"chat_id": chatID,
		"text":    text,
	}, &out)
	return out, err
}

func (c *Client) SendFile(
	ctx context.Context,
	chatID string,
	path string,
	mimeType *string,
	fileName *string,
	widthPx *int,
	heightPx *int,
) (SendFileResult, error) {
	var out SendFileResult
	err := c.request(ctx, "bot.v1.send_file", map[string]any{
		"chat_id":   chatID,
		"path":      path,
		"mime_type": mimeType,
		"file_name": fileName,
		"width_px":  widthPx,
		"height_px": heightPx,
	}, &out)
	return out, err
}

func (c *Client) DownloadFile(
	ctx context.Context,
	chatID string,
	messageID string,
	outputPath string,
) (DownloadFileResult, error) {
	var out DownloadFileResult
	err := c.request(ctx, "bot.v1.download_file", map[string]any{
		"chat_id":     chatID,
		"message_id":  messageID,
		"output_path": outputPath,
	}, &out)
	return out, err
}

func (c *Client) PublishKeyPackages(ctx context.Context, count int) (PublishKeyPackagesResult, error) {
	var out PublishKeyPackagesResult
	err := c.request(ctx, "bot.v1.publish_key_packages", map[string]any{
		"count": count,
	}, &out)
	return out, err
}

func (c *Client) Close() error {
	if c.cmd.Process == nil {
		return nil
	}
	_ = c.stdin.Close()
	return c.cmd.Wait()
}

func (c *Client) request(ctx context.Context, method string, params any, out any) error {
	c.mu.Lock()
	requestID := c.nextID
	c.nextID++
	ch := make(chan rpcEnvelope, 1)
	c.pending[requestID] = ch
	c.mu.Unlock()

	payload, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      requestID,
		"method":  method,
		"params":  params,
	})
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(c.stdin, "%s\n", payload); err != nil {
		return err
	}

	select {
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, requestID)
		c.mu.Unlock()
		return ctx.Err()
	case envelope := <-ch:
		if envelope.Error != nil {
			return envelope.Error
		}
		if out == nil {
			return nil
		}
		return json.Unmarshal(envelope.Result, out)
	}
}

func (c *Client) readLoop(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Bytes()
		var envelope rpcEnvelope
		if err := json.Unmarshal(line, &envelope); err != nil {
			continue
		}

		if envelope.ID != nil {
			c.mu.Lock()
			ch := c.pending[*envelope.ID]
			delete(c.pending, *envelope.ID)
			c.mu.Unlock()
			if ch != nil {
				ch <- envelope
			}
			continue
		}

		if envelope.Method != "" {
			c.notifications <- Notification{
				Method: envelope.Method,
				Params: envelope.Params,
			}
		}
	}
	close(c.notifications)
}
