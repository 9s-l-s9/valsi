;;; valsi-server-test.el --- Tests for AAP JSON-RPC transport -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Code:

(require 'ert)
(require 'json)
(require 'valsi-server)

(defun valsi-server-test--server ()
  "Return (SERVER . OUTPUT-CELL) with captured output."
  (let ((output (list "")))
    (cons
     (valsi-server-create
      :send-function
      (lambda (record)
        (setcar output (concat (car output) record))))
     output)))

(defun valsi-server-test--records (output)
  "Parse strict JSONL OUTPUT into response plists."
  (mapcar
   (lambda (line)
     (json-parse-string line :object-type 'plist :array-type 'array
                        :null-object :null :false-object :false))
   (split-string output "\n" t)))

(ert-deftest valsi-test-server-partial-concurrent-and-ids ()
  (valsi-proto-reset)
  (pcase-let* ((`(,server . ,output) (valsi-server-test--server))
               (request-1
                "{\"jsonrpc\":\"2.0\",\"id\":\"one\",\"method\":\"initialize\"}")
               (request-2
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"grammar/list\"}"))
    (valsi-server-consume server (substring request-1 0 20))
    (should (string-empty-p (car output)))
    (valsi-server-consume
     server (concat (substring request-1 20) "\n" request-2 "\n"))
    (let ((records (valsi-server-test--records (car output))))
      (should (equal '("one" 2) (mapcar (lambda (r) (plist-get r :id)) records)))
      (should (equal "2.0" (plist-get (car records) :jsonrpc)))
      (should (member "artifact/symbols"
                      (append (plist-get (plist-get (car records) :result)
                                         :capabilities)
                              nil))))))

(ert-deftest valsi-test-server-notification-has-no-response ()
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (valsi-server-consume
     server
     "{\"jsonrpc\":\"2.0\",\"method\":\"artifact/didClose\",\"params\":{\"uri\":\"x\"}}\n")
    (should (string-empty-p (car output)))))

(ert-deftest valsi-test-server-malformed-invalid-and-unknown-errors ()
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (valsi-server-consume
     server
     (concat
      "{broken}\n"
      "{\"jsonrpc\":\"1.0\",\"id\":3,\"method\":\"initialize\"}\n"
      "{\"jsonrpc\":\"2.0\",\"id\":\"x\",\"method\":\"missing\"}\n"
      "{\"jsonrpc\":\"2.0\",\"id\":{},\"method\":\"initialize\"}\n"))
    (let* ((records (valsi-server-test--records (car output)))
           (codes (mapcar (lambda (r)
                            (plist-get (plist-get r :error) :code))
                          records)))
      (should (equal '(-32700 -32600 -32601 -32600) codes))
      (should (eq :null (plist-get (car records) :id)))
      (should (equal 3 (plist-get (nth 1 records) :id)))
      (should (equal "x" (plist-get (nth 2 records) :id))))))

(ert-deftest valsi-test-server-strict-lf-and-unicode-separators ()
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (let ((uri (concat "a" (string #x2028) "b" (string #x2029) ".md")))
      (valsi-server-consume
       server
       (concat
        (json-serialize
         (list :jsonrpc "2.0" :id 1 :method "artifact/didOpen"
               :params (list :uri uri :text "# Fine")))
        "\n"))
      (should (equal uri
                     (plist-get
                      (plist-get
                       (car (valsi-server-test--records (car output))) :result)
                      :uri))))
    (setcar output "")
    (valsi-server-consume
     server "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\"}\r\n")
    (should (= -32700
               (plist-get
                (plist-get
                 (car (valsi-server-test--records (car output))) :error)
                :code)))))

(ert-deftest valsi-test-server-eof-reports-partial-and-closes ()
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (valsi-server-consume
     server "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}")
    (valsi-server-eof server)
    (let ((response (car (valsi-server-test--records (car output)))))
      (should (= -32700 (plist-get (plist-get response :error) :code))))
    (should-error (valsi-server-consume server "\n"))))

(ert-deftest valsi-test-server-artifact-methods-and-plan-context ()
  (valsi-server-init)
  (valsi-proto-reset)
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (dolist
        (request
         (list
          (list :jsonrpc "2.0" :id 1 :method "artifact/didOpen"
                :params (list :uri "PLAN.md"
                              :text "- [ ] T900 Wire `lisp/x.el`\n"))
          (list :jsonrpc "2.0" :id 2 :method "artifact/capabilities"
                :params (list :uri "PLAN.md"))
          (list :jsonrpc "2.0" :id 3 :method "artifact/symbols"
                :params (list :uri "PLAN.md"))
          (list :jsonrpc "2.0" :id 4 :method "artifact/planContext"
                :params (list :uri "PLAN.md" :taskId "T900"))))
      (valsi-server-consume server
                           (concat (json-serialize request) "\n")))
    (let* ((records (valsi-server-test--records (car output)))
           (opened (plist-get (nth 0 records) :result))
           (caps (plist-get (plist-get (nth 1 records) :result)
                            :capabilities))
           (symbols (plist-get (nth 2 records) :result))
           (context (plist-get (nth 3 records) :result)))
      (should (equal "plan" (plist-get opened :grammar)))
      (should (> (length caps) 0))
      (should (equal "plan" (plist-get symbols :type)))
      (should (equal "T900" (plist-get context :id)))
      (should (equal ["lisp/x.el"] (plist-get context :files))))))

(ert-deftest valsi-test-server-real-stdio-roundtrip-and-eof ()
  "A headless Emacs serves one request and exits cleanly when stdin closes."
  ;; valsi-server-stdio reads the process's own stdin via /proc/PID/fd/0, so the
  ;; test only applies where that interface exists.
  (skip-unless (file-exists-p "/proc/self/fd/0"))
  (let ((program
         (or ;; The running binary, even when Emacs was launched off PATH by
             ;; an absolute store path (invocation-name is then unfindable).
             (let ((self (expand-file-name invocation-name invocation-directory)))
               (and (file-executable-p self) self))
             (executable-find invocation-name)
             (executable-find "emacs"))))
    (skip-unless program)
    (with-temp-buffer
      (insert "{\"jsonrpc\":\"2.0\",\"id\":\"live\",\"method\":\"initialize\"}\n")
      (let ((status
             (call-process-region
              (point-min) (point-max) program t t nil
              "-Q" "--batch" "-L" (expand-file-name "lisp" default-directory)
              "-l" "valsi-server" "-f" "valsi-server-stdio")))
        (should (zerop status))
        (goto-char (point-min))
        (let ((response
               (json-parse-string
                (buffer-substring-no-properties
                 (point) (line-end-position))
                :object-type 'plist :array-type 'array
                :null-object :null :false-object :false)))
          (should (equal "live" (plist-get response :id)))
          (should (vectorp
                   (plist-get (plist-get response :result)
                              :capabilities))))))))

;;;; Regression tests for reported wire bugs

(defun valsi-server-test--exchange (&rest records)
  "Feed each of RECORDS (a plist or raw JSON string); return the responses."
  (pcase-let ((`(,server . ,output) (valsi-server-test--server)))
    (dolist (record records)
      (valsi-server-consume
       server (concat (if (stringp record) record (json-serialize record))
                      "\n")))
    (valsi-server-test--records (car output))))

(defun valsi-server-test--codes (responses)
  "Return the error code of each of RESPONSES, or nil for a result."
  (mapcar (lambda (r) (plist-get (plist-get r :error) :code)) responses))

(ert-deftest valsi-test-server-empty-results-are-arrays-or-null ()
  "Issue #5: nil never reaches the wire as {} for an array or absent result."
  (valsi-server-init)
  (valsi-proto-reset)
  (unwind-protect
      (let* ((responses
              (valsi-server-test--exchange
               (list :jsonrpc "2.0" :id 1 :method "grammar/register"
                     :params (list :spec (list :id "issue5x"
                                               :match (list :uriSuffix ".x")
                                               :recognizers [])))
               (list :jsonrpc "2.0" :id 2 :method "artifact/didOpen"
                     :params (list :uri "a.x" :text "zz"))
               (list :jsonrpc "2.0" :id 3 :method "artifact/capabilities"
                     :params (list :uri "zzz"))
               (list :jsonrpc "2.0" :id 4 :method "grammar/describe"
                     :params (list :id "nope"))
               (list :jsonrpc "2.0" :id 5 :method "grammar/describe"
                     :params (list :id "issue5x"))))
             (results (mapcar (lambda (r) (plist-get r :result)) responses)))
        (should (equal "issue5x" (plist-get (nth 1 results) :grammar)))
        (should (equal [] (plist-get (nth 1 results) :capabilities)))
        (should (equal [] (plist-get (nth 2 results) :capabilities)))
        (should (eq :null (nth 3 results)))
        (should (equal "issue5x" (plist-get (nth 4 results) :id)))
        (should (equal [] (plist-get (nth 4 results) :commands))))
    (valsi-registry-unregister 'issue5x)
    (valsi-proto-reset)))

(ert-deftest valsi-test-server-non-string-uri-text-is-invalid-params ()
  "Issue #27: non-string or missing uri/text answers -32602."
  (valsi-server-init)
  (valsi-proto-reset)
  (unwind-protect
      (let ((responses
             (valsi-server-test--exchange
              (list :jsonrpc "2.0" :id 1 :method "artifact/didOpen"
                    :params (list :uri 5 :text "x"))
              (list :jsonrpc "2.0" :id 2 :method "artifact/didOpen"
                    :params (list :uri "u" :text 5))
              (list :jsonrpc "2.0" :id 3 :method "artifact/didChange"
                    :params (list :uri "u"))
              (list :jsonrpc "2.0" :id 4 :method "artifact/symbols"
                    :params (list :uri ["x"]))
              (list :jsonrpc "2.0" :id 5 :method "artifact/capabilities"
                    :params (list :uri 1))
              (list :jsonrpc "2.0" :id 6 :method "artifact/planContext"
                    :params (list :uri "u" :taskId 7))
              (list :jsonrpc "2.0" :id 7 :method "artifact/didClose"
                    :params (list :uri :false))
              (list :jsonrpc "2.0" :id 8 :method "grammar/detect"
                    :params (list :uri 3))
              (list :jsonrpc "2.0" :id 9 :method "artifact/didOpen"
                    :params (list :uri "u" :text "x")))))
        (should (equal '(-32602 -32602 -32602 -32602 -32602 -32602 -32602
                         -32602 nil)
                       (valsi-server-test--codes responses)))
        (should (equal '("u") (valsi-proto-open-uris))))
    (valsi-proto-reset)))

(ert-deftest valsi-test-server-lone-surrogate-is-parse-error ()
  "Issue #28: an undecodable surrogate escape answers -32700, not -32600."
  (valsi-proto-reset)
  (let ((responses
         (valsi-server-test--exchange
          (concat "{\"jsonrpc\":\"2.0\",\"id\":10,"
                  "\"method\":\"artifact/didOpen\","
                  "\"params\":{\"uri\":\"file:///b.md\","
                  "\"text\":\"\\ud83d\"}}")
          ;; A decodable record that is not an object stays -32600.
          "[1,2]")))
    (should (equal '(-32700 -32600) (valsi-server-test--codes responses)))
    (should (eq :null (plist-get (car responses) :id)))
    (should-not (valsi-proto-open-uris))))

(ert-deftest valsi-test-server-invalid-grammar-spec-is-invalid-params ()
  "Issue #29: a bad grammar/register spec or describe id answers -32602."
  (valsi-server-init)
  (valsi-proto-reset)
  (let* ((grammars (valsi-registry-all))
         (responses
          (valsi-server-test--exchange
           (list :jsonrpc "2.0" :id 7 :method "grammar/register"
                 :params (list :name "x"))
           (list :jsonrpc "2.0" :id 8 :method "grammar/register"
                 :params (list :spec (list :id "bad" :match (list :score 1))))
           (list :jsonrpc "2.0" :id 9 :method "grammar/register"
                 :params (list :spec (list :id "bad"
                                           :match (list :uriSuffix ".b")
                                           :recognizers
                                           (vector (list :type "t"
                                                         :regexp "\\(")))))
           (list :jsonrpc "2.0" :id 10 :method "grammar/register"
                 :params (list :spec "plan"))
           (list :jsonrpc "2.0" :id 11 :method "grammar/describe"
                 :params (list :name 5))
           (list :jsonrpc "2.0" :id 12 :method "grammar/describe"
                 :params (list :id 5))
           (list :jsonrpc "2.0" :id 13 :method "grammar/describe"
                 :params (list :id "plan")))))
    (should (equal '(-32602 -32602 -32602 -32602 -32602 -32602 nil)
                   (valsi-server-test--codes responses)))
    (should (string-match-p ":spec must be"
                            (plist-get (plist-get (car responses) :error)
                                       :data)))
    (should (equal "plan" (plist-get (plist-get (nth 6 responses) :result)
                                     :id)))
    (should (equal grammars (valsi-registry-all)))))

(provide 'valsi-server-test)
;;; valsi-server-test.el ends here
