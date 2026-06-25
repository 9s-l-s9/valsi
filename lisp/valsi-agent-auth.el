;;; valsi-agent-auth.el --- Subscription OAuth for the Valsi agent core -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Subscription-OAuth-first authentication (ADR 0003, research/03 Pattern 3b,
;; constants in research/03a).  The maintainer authenticates with a Claude
;; subscription, not an API key, so this is the default path.
;;
;; Resolution order (least friction first):
;;   1. reuse Claude Code's credential: CLAUDE_CODE_OAUTH_TOKEN env, then
;;      ~/.claude/.credentials.json, then (macOS) the Keychain;
;;   2. Valsi's own store at ~/.valsi/auth.json;
;;   3. a first-party PKCE login only if nothing above resolves.
;; Tokens auto-refresh on a 5-minute skew; a token sourced from Claude Code is
;; written back there so other tools stay in sync.
;;
;; The OAuth endpoint constants are undocumented and drift -- they live in ONE
;; defconst block so a constant change degrades to "re-login", not "broken".
;; Re-verify against research/03a and the `claude-api' skill before shipping.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'url)

;;;; Constants (research/03a §1 -- keep them all here)

(defconst valsi-agent-auth-client-id "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
  "The Claude Code OAuth client id (shared across tau/pi/Hermes).")
(defconst valsi-agent-auth-authorize-url "https://claude.ai/oauth/authorize"
  "OAuth authorize endpoint (browser).")
(defconst valsi-agent-auth-token-url "https://platform.claude.com/v1/oauth/token"
  "OAuth token endpoint (exchange + refresh).  See research/03a §6.")
(defconst valsi-agent-auth-callback-host "127.0.0.1"
  "Loopback host for the PKCE callback server.")
(defconst valsi-agent-auth-callback-port 53692
  "Loopback port for the PKCE callback (pi's value).")
(defconst valsi-agent-auth-scopes
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
  "OAuth scopes requested for a subscription session.")
(defconst valsi-agent-auth-refresh-skew 300
  "Seconds before expiry at which a token is proactively refreshed (5 min).")

(defvar valsi-agent-auth-file
  (expand-file-name "~/.valsi/auth.json")
  "Where Valsi persists its own OAuth credential when it runs the login flow.")

;;;; Credential

(cl-defstruct (valsi-agent-auth-credential
               (:constructor valsi-agent-auth-credential-create))
  "A resolved OAuth credential.
ACCESS/REFRESH are token strings; EXPIRES is epoch seconds (float); ACCOUNT-ID
is optional; SOURCE is a symbol recording its origin (for write-back)."
  access refresh expires account-id (source 'unknown))

(defun valsi-agent-auth--now () "Return the current time as epoch seconds." (float-time))

(defun valsi-agent-auth-expired-p (cred &optional skew)
  "Return non-nil if CRED expires within SKEW seconds (default the skew const)."
  (let ((exp (valsi-agent-auth-credential-expires cred)))
    (or (null exp)
        (<= exp (+ (valsi-agent-auth--now) (or skew valsi-agent-auth-refresh-skew))))))

(defun valsi-agent-auth-token-type (token)
  "Classify TOKEN (03a §5) as `setup', `oauth', `claude-code', `api', or nil."
  (cond ((null token) nil)
        ((string-prefix-p "sk-ant-api" token) 'api)
        ((string-prefix-p "sk-ant-" token) 'setup)
        ((string-prefix-p "cc-" token) 'claude-code)
        ((string-prefix-p "eyJ" token) 'oauth)
        (t 'oauth)))

;;;; PKCE (S256)

(defun valsi-agent-auth--b64url (bytes)
  "Return the unpadded base64url encoding of BYTES."
  (base64url-encode-string bytes t))

(defun valsi-agent-auth--pkce-verifier ()
  "Return a fresh PKCE code verifier (43-char base64url).
Seeded from several high-entropy sources through SHA-256; the verifier never
leaves this process (only its challenge is sent)."
  (valsi-agent-auth--b64url
   (secure-hash 'sha256
                (format "%s-%s-%s-%s" (random most-positive-fixnum)
                        (float-time) (emacs-pid) (make-temp-name "v"))
                nil nil t)))

(defun valsi-agent-auth--pkce-challenge (verifier)
  "Return the S256 PKCE challenge for VERIFIER."
  (valsi-agent-auth--b64url (secure-hash 'sha256 verifier nil nil t)))

;;;; Credential discovery (reuse before login)

(defun valsi-agent-auth--from-env ()
  "Return a credential from the CLAUDE_CODE / ANTHROPIC OAuth env vars, or nil."
  (let ((tok (or (getenv "CLAUDE_CODE_OAUTH_TOKEN")
                 (getenv "ANTHROPIC_OAUTH_TOKEN"))))
    (when (and tok (not (string-empty-p tok)))
      (valsi-agent-auth-credential-create :access tok :expires nil :source 'env))))

(defun valsi-agent-auth--parse-json-file (file)
  "Read FILE as JSON into a plist, or nil on error/missing."
  (when (file-readable-p file)
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents file)
        (json-parse-buffer :object-type 'plist :array-type 'list)))))

(defun valsi-agent-auth--coerce-expires (v)
  "Coerce an expiry V (ms epoch, s epoch, or nil) to epoch seconds or nil."
  (cond ((null v) nil)
        ((numberp v) (if (> v 1e11) (/ v 1000.0) (float v))) ; ms vs s heuristic
        ((stringp v) (valsi-agent-auth--coerce-expires (string-to-number v)))
        (t nil)))

(defun valsi-agent-auth--from-plist (pl source)
  "Build a credential from plist PL (tolerant of key spellings), tagged SOURCE."
  (let* ((oauth (or (plist-get pl :claudeAiOauth) pl))
         (access (or (plist-get oauth :accessToken) (plist-get oauth :access_token)
                     (plist-get oauth :access)))
         (refresh (or (plist-get oauth :refreshToken) (plist-get oauth :refresh_token)
                      (plist-get oauth :refresh)))
         (expires (valsi-agent-auth--coerce-expires
                   (or (plist-get oauth :expiresAt) (plist-get oauth :expires_at)
                       (plist-get oauth :expires))))
         (account (or (plist-get oauth :account_id) (plist-get oauth :accountId))))
    (when access
      (valsi-agent-auth-credential-create
       :access access :refresh refresh :expires expires
       :account-id account :source source))))

(defun valsi-agent-auth--from-claude-file ()
  "Return a credential from Claude Code's on-disk store, or nil."
  (cl-some (lambda (f) (let ((pl (valsi-agent-auth--parse-json-file
                                  (expand-file-name f))))
                         (and pl (valsi-agent-auth--from-plist pl 'claude-code))))
           '("~/.claude/.credentials.json" "~/.claude.json")))

(defun valsi-agent-auth--from-valsi-file ()
  "Return a credential from Valsi's own store, or nil."
  (let ((pl (valsi-agent-auth--parse-json-file valsi-agent-auth-file)))
    (and pl (valsi-agent-auth--from-plist pl 'valsi))))

(defun valsi-agent-auth-resolve ()
  "Resolve a credential from the environment, Claude Code, or Valsi's store.
Returns a `valsi-agent-auth-credential' or nil (meaning: a login is required)."
  (or (valsi-agent-auth--from-env)
      (valsi-agent-auth--from-claude-file)
      (valsi-agent-auth--from-valsi-file)))

;;;; Persistence

(defun valsi-agent-auth--credential-to-plist (cred)
  "Return CRED as a JSON-ready plist for Valsi's store."
  (list :access (valsi-agent-auth-credential-access cred)
        :refresh (or (valsi-agent-auth-credential-refresh cred) :null)
        :expires (or (valsi-agent-auth-credential-expires cred) :null)
        :account_id (or (valsi-agent-auth-credential-account-id cred) :null)))

(defun valsi-agent-auth-save (cred)
  "Persist CRED to Valsi's store (`valsi-agent-auth-file').  Returns CRED."
  (make-directory (file-name-directory valsi-agent-auth-file) t)
  (with-temp-file valsi-agent-auth-file
    (insert (json-serialize (valsi-agent-auth--credential-to-plist cred))))
  (set-file-modes valsi-agent-auth-file #o600)
  cred)

;;;; Token exchange + refresh (network -- not exercised in CI)

(defun valsi-agent-auth--post-json (url payload)
  "POST PAYLOAD (a plist) to URL as JSON; return the parsed response plist."
  (let ((url-request-method "POST")
        (url-request-extra-headers '(("Content-Type" . "application/json")))
        (url-request-data (encode-coding-string (json-serialize payload) 'utf-8)))
    (with-current-buffer (url-retrieve-synchronously url t t 30)
      (goto-char (point-min))
      (re-search-forward "\n\n" nil t)
      (prog1 (json-parse-buffer :object-type 'plist :array-type 'list)
        (kill-buffer)))))

(defun valsi-agent-auth--credential-from-response (resp source &optional refresh-fallback)
  "Build a credential from token-endpoint RESP, tagged SOURCE.
REFRESH-FALLBACK keeps the prior refresh token if the response rotates none."
  (let ((expires-in (plist-get resp :expires_in)))
    (valsi-agent-auth-credential-create
     :access (plist-get resp :access_token)
     :refresh (or (plist-get resp :refresh_token) refresh-fallback)
     :expires (and expires-in (+ (valsi-agent-auth--now) expires-in
                                 (- valsi-agent-auth-refresh-skew)))
     :account-id (plist-get resp :account_id)
     :source source)))

(defun valsi-agent-auth-refresh (cred)
  "Refresh CRED at the token endpoint (zero LLM tokens); return a new credential.
Writes back to Valsi's store; a caller that sourced CRED from Claude Code should
prefer leaving Claude Code's own store authoritative (see ADR 0003)."
  (unless (valsi-agent-auth-credential-refresh cred)
    (user-error "No refresh token; a fresh login is required"))
  (let* ((resp (valsi-agent-auth--post-json
                valsi-agent-auth-token-url
                (list :grant_type "refresh_token"
                      :client_id valsi-agent-auth-client-id
                      :refresh_token (valsi-agent-auth-credential-refresh cred))))
         (new (valsi-agent-auth--credential-from-response
               resp (valsi-agent-auth-credential-source cred)
               (valsi-agent-auth-credential-refresh cred))))
    (valsi-agent-auth-save new)))

(defun valsi-agent-auth-token ()
  "Return a valid access-token string, resolving + refreshing as needed.
Signals if no credential resolves and no login has been performed."
  (let ((cred (valsi-agent-auth-resolve)))
    (unless cred
      (user-error "No Claude credential found; run `valsi-agent-auth-login'"))
    (when (and (valsi-agent-auth-expired-p cred)
               (valsi-agent-auth-credential-refresh cred))
      (setq cred (valsi-agent-auth-refresh cred)))
    (valsi-agent-auth-credential-access cred)))

;;;; First-party PKCE login (network + loopback -- not exercised in CI)

(defun valsi-agent-auth--authorize-url (challenge verifier)
  "Return the browser authorize URL for CHALLENGE (state = VERIFIER)."
  (concat valsi-agent-auth-authorize-url "?"
          (url-build-query-string
           `(("code" "true")
             ("client_id" ,valsi-agent-auth-client-id)
             ("response_type" "code")
             ("redirect_uri" ,(format "http://%s:%d/callback"
                                      valsi-agent-auth-callback-host
                                      valsi-agent-auth-callback-port))
             ("scope" ,valsi-agent-auth-scopes)
             ("code_challenge" ,challenge)
             ("code_challenge_method" "S256")
             ("state" ,verifier)))))

(defun valsi-agent-auth--exchange (code verifier)
  "Exchange authorization CODE (with VERIFIER) for a credential and save it."
  (let ((resp (valsi-agent-auth--post-json
               valsi-agent-auth-token-url
               (list :grant_type "authorization_code"
                     :client_id valsi-agent-auth-client-id
                     :code code :state verifier
                     :redirect_uri (format "http://%s:%d/callback"
                                           valsi-agent-auth-callback-host
                                           valsi-agent-auth-callback-port)
                     :code_verifier verifier))))
    (valsi-agent-auth-save
     (valsi-agent-auth--credential-from-response resp 'valsi))))

(defun valsi-agent-auth-login ()
  "Run the first-party PKCE login flow and persist the credential.
Opens the browser to the authorize URL and accepts either the loopback callback
or a manually pasted code (research/03a §2)."
  (interactive)
  (let* ((verifier (valsi-agent-auth--pkce-verifier))
         (challenge (valsi-agent-auth--pkce-challenge verifier))
         (url (valsi-agent-auth--authorize-url challenge verifier)))
    (browse-url url)
    (let* ((pasted (read-string
                    "Paste the code (or the full redirect URL) from the browser: "))
           (code (valsi-agent-auth--extract-code pasted)))
      (valsi-agent-auth--exchange code verifier)
      (message "Valsi: subscription login complete"))))

(defun valsi-agent-auth--extract-code (input)
  "Extract an authorization code from INPUT (a raw code, `code#state', or URL)."
  (cond
   ((string-match "[?&]code=\\([^&]+\\)" input) (match-string 1 input))
   ((string-match "\\`\\([^#]+\\)#" input) (match-string 1 input))
   (t (string-trim input))))

(provide 'valsi-agent-auth)
;;; valsi-agent-auth.el ends here
