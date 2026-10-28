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

(ert-deftest valsi-test-server-rejects-catastrophic-regexps ()
  "Issue #80: wire grammars cannot register exponential regexps."
  (valsi-server-init)
  (valsi-proto-reset)
  (let* ((grammars (valsi-registry-all))
         (evil '("\\(a*\\)*b" "\\(a+\\)+$" "\\(a\\|aa\\)*b" "\\(?:a*\\)+"
                 "\\(a*\\)\\{2,\\}" "\\(\\(a\\)*\\)*" "\\(x\\)\\1"))
         (id 0)
         (requests
          (cl-loop
           for re in evil
           append
           (list (list :jsonrpc "2.0" :id (cl-incf id)
                       :method "grammar/register"
                       :params (list :spec (list :id "evil"
                                                 :match (list :textRegexp re)
                                                 :recognizers [])))
                 (list :jsonrpc "2.0" :id (cl-incf id)
                       :method "grammar/register"
                       :params (list :spec (list :id "evil"
                                                 :match (list :uriRegexp re)
                                                 :recognizers [])))
                 (list :jsonrpc "2.0" :id (cl-incf id)
                       :method "grammar/register"
                       :params
                       (list :spec
                             (list :id "evil"
                                   :match (list :uriSuffix ".evil")
                                   :recognizers
                                   (vector (list :type "x" :regexp re))))))))
         (responses
          (apply #'valsi-server-test--exchange
                 (append requests
                         (list (list :jsonrpc "2.0" :id "after"
                                     :method "initialize"))))))
    (should (equal (append (make-list (* 3 (length evil)) -32602) '(nil))
                   (valsi-server-test--codes responses)))
    (should (string-match-p "rejected"
                            (plist-get (plist-get (car responses) :error)
                                       :data)))
    (should (equal grammars (valsi-registry-all)))
    ;; Ordinary regexps are still accepted.
    (dolist (re '("^\\(#+\\) \\(.*\\)$" "\\(foo\\)?bar" "[(*]+"
                  "^- \\[\\([ x]\\)\\] \\(T[0-9]+\\) \\(.*\\)$"
                  "\\`[]*]+\\(x\\)*" "\\`[[:alpha:]*]+\\(y\\)+"))
      (should-not (valsi-registry--regexp-risk re t)))))

(defconst valsi-server-test--polynomial-regexps
  '("a*a*a*a*a*b" ".*.*.*.*x" "[a-z]*[a-z]*[a-z]*[a-z]*[a-z]*!x")
  "Polynomially backtracking regexps from the review of issue #80.")

(defun valsi-server-test--register (id match &optional recognizers)
  "Return a grammar/register request for ID with MATCH and RECOGNIZERS."
  (list :jsonrpc "2.0" :id id :method "grammar/register"
        :params (list :spec (list :id id :match match
                                  :recognizers (vconcat recognizers)))))

(ert-deftest valsi-test-server-rejects-polynomial-regexps ()
  "Issue #80: polynomial backtracking beyond O(N^2) is rejected."
  (valsi-server-init)
  (valsi-proto-reset)
  (let* ((grammars (valsi-registry-all))
         (line (concat (make-string 3900 ?a) "\n"))
         (start (float-time))
         (responses
          (apply
           #'valsi-server-test--exchange
           (append
            (cl-loop
             for re in valsi-server-test--polynomial-regexps
             append
             (list (valsi-server-test--register
                    "poly" (list :textRegexp re :score 1000))
                   (valsi-server-test--register
                    "poly" (list :uriRegexp re :score 1000))
                   (valsi-server-test--register
                    "poly" (list :uriSuffix ".poly")
                    (list (list :type "x" :regexp re)))
                   ;; Anchoring removes only the search loop's degree.
                   (valsi-server-test--register
                    "poly" (list :uriSuffix ".poly")
                    (list (list :type "x" :regexp (concat "^" re))))))
            (list (list :jsonrpc "2.0" :id "open" :method "artifact/didOpen"
                        :params (list :uri "f.poly" :text line))
                  (list :jsonrpc "2.0" :id "after" :method "initialize"))))))
    (should (equal (append (make-list (* 4 3) -32602) '(nil nil))
                   (valsi-server-test--codes responses)))
    (should (string-match-p "rejected (too many unbounded"
                            (plist-get (plist-get (car responses) :error)
                                       :data)))
    (should (< (- (float-time) start) 5))
    (should (equal grammars (valsi-registry-all)))
    (valsi-proto-reset)))

(ert-deftest valsi-test-server-accepted-regexps-stay-fast ()
  "Issue #80: legitimate regexps register and run quickly on long input."
  (valsi-server-init)
  (valsi-proto-reset)
  (let ((legit
         ;; The AAP spec example and the regexps of the declarative tests,
         ;; plus accepted patterns at the O(N^2) worst case.
         '(("^ITEM: +\\(.*\\)$" . t) ("^MARK: +\\(.*\\)$" . t)
           ("^# +\\(.*\\)$" . t) ("^\\(#+\\) \\(.*\\)$" . t)
           ("^- \\[\\([ x]\\)\\] \\(T[0-9]+\\) \\(.*\\)$" . t)
           ("^ITEM" . t) ("^hi" . t) ("^x" . t) ("^[a-z]*[a-z]*!x" . t)
           ("MAGIC" . nil) ("\\.bnd\\'" . nil) ("\\(foo\\)?bar" . nil)
           (".*x" . nil) ("[a-z]*!x" . nil) ("\\`.*.*x" . nil)
           ("\\`a*a*b" . nil) ("\\(?:foo\\|bar\\).*baz" . nil)))
        (long (make-string 3900 ?a)))
    (unwind-protect
        (dolist (entry legit)
          (let* ((re (car entry))
                 (spec (if (cdr entry)
                           (list (list :uriSuffix ".legit")
                                 (list (list :type "x" :regexp re)))
                         (list (list :textRegexp re :uriRegexp re))))
                 (start (float-time))
                 (responses
                  (valsi-server-test--exchange
                   (apply #'valsi-server-test--register "legit" spec)
                   (list :jsonrpc "2.0" :id 2 :method "grammar/detect"
                         :params (list :uri long :text long))
                   (list :jsonrpc "2.0" :id 3 :method "artifact/didOpen"
                         :params (list :uri "a.legit"
                                       :text (concat long "\n"
                                                     (substring long 0 1999)
                                                     "\n"))))))
            (should (equal (list re nil nil nil)
                           (cons re (valsi-server-test--codes responses))))
            (should (< (- (float-time) start) 2))))
      (valsi-registry-unregister 'legit)
      (valsi-proto-reset))))

(ert-deftest valsi-test-server-declarative-deadline-bounds-request ()
  "Issue #80: declared regexps stop matching after the request deadline."
  (let* ((parse (valsi-registry--declarative-parser
                 'dl 'document (list (list :type "x" :regexp "^x"))))
         (match (valsi-registry--declarative-matcher
                 (list :textRegexp "x" :score 7)))
         (text "x\nx\n"))
    (should (= 2 (length (valsi-node-children (funcall parse text)))))
    (should (= 7 (funcall match "u" text)))
    (let ((valsi-registry--declarative-deadline (1- (float-time))))
      (should-not (valsi-node-children (funcall parse text)))
      (should (= 0 (funcall match "u" text))))))

(ert-deftest valsi-test-server-real-stdio-survives-hostile-register ()
  "Issue #80: requests after a hostile grammar/register are still answered."
  (skip-unless (file-exists-p "/proc/self/fd/0"))
  (skip-unless (valsi-server-test--emacs-program))
  (let* ((line (concat (make-string 3900 ?a) "\n"))
         (records
          (append
           (cl-loop for re in valsi-server-test--polynomial-regexps
                    for n from 1
                    append
                    (list (valsi-server-test--register
                           (format "evil%d" n)
                           (list :textRegexp re :score 1000))
                          (valsi-server-test--register
                           (format "evil%d" n) (list :uriSuffix ".evil")
                           (list (list :type "x" :regexp re)))))
           ;; The costliest shape that is accepted.
           (list (valsi-server-test--register
                  "quad" (list :uriSuffix ".evil" :score 2000)
                  (list (list :type "x" :regexp "^[a-z]*[a-z]*!x")))
                 (list :jsonrpc "2.0" :id "open" :method "artifact/didOpen"
                       :params (list :uri "f.evil"
                                     :text (concat line
                                                   (substring line 0 1999)
                                                   "\n")))
                 (list :jsonrpc "2.0" :id "list" :method "grammar/list")
                 (list :jsonrpc "2.0" :id "init" :method "initialize"))))
         (output "")
         (process
          (make-process
           :name "valsi-hostile" :connection-type 'pipe :noquery t
           :command (list (valsi-server-test--emacs-program)
                          "-Q" "--batch"
                          "--eval" "(setq load-prefer-newer t)"
                          "-L" (expand-file-name "lisp" default-directory)
                          "-l" "valsi-server" "-f" "valsi-server-stdio")
           :filter (lambda (_proc string)
                     (setq output (concat output string)))
           :stderr (get-buffer-create " *valsi-hostile-stderr*")))
         (deadline (+ (float-time) 15)))
    (unwind-protect
        (progn
          (dolist (record records)
            (process-send-string process
                                 (concat (json-serialize record) "\n")))
          (process-send-eof process)
          (while (and (process-live-p process) (< (float-time) deadline))
            (accept-process-output process 0.1))
          (should-not (process-live-p process))
          (let ((responses (valsi-server-test--records output)))
            (should (equal (append (make-list 6 -32602) '(nil nil nil nil))
                           (valsi-server-test--codes responses)))
            (should (equal "init" (plist-get (car (last responses)) :id)))))
      (when (process-live-p process) (kill-process process))
      (kill-buffer " *valsi-hostile-stderr*"))))

(ert-deftest valsi-test-server-declarative-match-input-is-bounded ()
  "Issue #80: declared regexps only see bounded input."
  (valsi-server-init)
  (valsi-proto-reset)
  (unwind-protect
      (let* ((limit valsi-registry-declarative-match-limit)
             (late (concat (make-string limit ?\s) "MAGIC\n"))
             (long-line (concat "ITEM " (make-string limit ?x) "\n"))
             (responses
              (valsi-server-test--exchange
               (list :jsonrpc "2.0" :id 1 :method "grammar/register"
                     :params
                     (list :spec
                           (list :id "bounded"
                                 :match (list :textRegexp "MAGIC"
                                              :uriRegexp "\\.bnd\\'"
                                              :score 1000)
                                 :recognizers
                                 (vector (list :type "item"
                                               :regexp "^ITEM")))))
               (list :jsonrpc "2.0" :id 2 :method "grammar/detect"
                     :params (list :uri "a.txt" :text "MAGIC\n"))
               (list :jsonrpc "2.0" :id 3 :method "grammar/detect"
                     :params (list :uri "a.txt" :text late))
               (list :jsonrpc "2.0" :id 4 :method "grammar/detect"
                     :params (list :uri (concat (make-string limit ?u)
                                                ".bnd")
                                   :text ""))
               (list :jsonrpc "2.0" :id 5 :method "artifact/didOpen"
                     :params (list :uri "b.bnd"
                                   :text (concat "ITEM short\n" long-line)))
               (list :jsonrpc "2.0" :id 6 :method "artifact/symbols"
                     :params (list :uri "b.bnd")))))
        (cl-flet ((detected (n)
                    (plist-get (plist-get (nth n responses) :result) :id)))
          (should (equal "bounded" (detected 1)))
          (should-not (equal "bounded" (detected 2)))
          (should-not (equal "bounded" (detected 3))))
        ;; The over-long line resolves less detail; it is not an error.
        (should (= 1 (length (plist-get (plist-get (nth 5 responses) :result)
                                        :children)))))
    (valsi-registry-unregister 'bounded)
    (valsi-proto-reset)))

(ert-deftest valsi-test-server-register-resyncs-each-document ()
  "Issue #81: one failing document neither aborts nor blocks registration."
  (valsi-server-init)
  (valsi-proto-reset)
  (unwind-protect
      (let ((open (lambda (uri text)
                    (list :jsonrpc "2.0" :id uri :method "artifact/didOpen"
                          :params (list :uri uri :text text))))
            (spec (lambda (id suffix)
                    (list :id id :match (list :uriSuffix suffix :score 50)
                          :recognizers (vector (list :type "x"
                                                     :regexp "^hi"))
                          :capabilities ["so-cap"]))))
        (valsi-server-test--exchange
         (funcall open "aa.so" "hi\n") (funcall open "big.boom" "hi\n")
         (funcall open "nest.boom" "nest\n") (funcall open "zz.so" "hi\n"))
        ;; A grammar that now fails on the already open .boom documents.
        (valsi-registry-register
         (list :id 'boom81 :name "boom"
               :match (lambda (uri _text)
                        (if (string-suffix-p ".boom" (or uri "")) 100 0))
               :parse (lambda (content)
                        (if (string-prefix-p "nest" content)
                            (signal 'excessive-lisp-nesting '(1601))
                          (error "Stack overflow in regexp matcher")))))
        (let* ((responses
                (valsi-server-test--exchange
                 (list :jsonrpc "2.0" :id "r" :method "grammar/register"
                       :params (list :spec (funcall spec "so81" ".so")))
                 (list :jsonrpc "2.0" :id "c" :method "artifact/capabilities"
                       :params (list :uri "zz.so"))
                 (list :jsonrpc "2.0" :id "r2" :method "grammar/register"
                       :params (list :spec (funcall spec "zzz81" ".zzz")))))
               (result (plist-get (car responses) :result))
               (failed (append (plist-get result :failed) nil)))
          (should (equal '(nil nil nil) (valsi-server-test--codes responses)))
          (should (equal "so81" (plist-get result :id)))
          (should (equal '("big.boom" "nest.boom")
                         (mapcar (lambda (f) (plist-get f :uri)) failed)))
          (should (string-match-p "Stack overflow"
                                  (plist-get (car failed) :message)))
          ;; Documents after the failing ones were re-resolved.
          (should (equal ["so-cap"]
                         (plist-get (plist-get (nth 1 responses) :result)
                                    :capabilities)))
          (should (eq 'so81 (valsi-proto-doc-grammar
                             (gethash "aa.so" valsi-proto--docs))))
          ;; Failed documents are closed and no longer block registration.
          (should (equal '("aa.so" "zz.so")
                         (sort (valsi-proto-open-uris) #'string<)))
          (should (equal [] (plist-get (plist-get (nth 2 responses) :result)
                                       :failed)))))
    (dolist (id '(boom81 so81 zzz81)) (valsi-registry-unregister id))
    (valsi-proto-reset)))

(defun valsi-server-test--emacs-program ()
  "Return the running Emacs binary for a real-stdio test, or nil."
  (or (let ((self (expand-file-name invocation-name invocation-directory)))
        (and (file-executable-p self) self))
      (executable-find invocation-name)
      (executable-find "emacs")))

(defun valsi-server-test--stdio-bytes (input &optional environment)
  "Run a real stdio server on unibyte INPUT; return its raw stdout bytes.
ENVIRONMENT entries are prepended to `process-environment'."
  (let ((program (valsi-server-test--emacs-program))
        (process-environment (append environment process-environment))
        (coding-system-for-read 'binary)
        (coding-system-for-write 'binary))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert input)
      (should (zerop (call-process-region
                      (point-min) (point-max) program t '(t nil) nil
                      "-Q" "--batch"
                      "--eval" "(setq load-prefer-newer t)"
                      "-L" (expand-file-name "lisp" default-directory)
                      "-l" "valsi-server" "-f" "valsi-server-stdio")))
      (buffer-string))))

(ert-deftest valsi-test-server-real-stdio-writes-utf-8 ()
  "Issue #79: non-ASCII output is valid UTF-8 on stdout, in any locale."
  (skip-unless (file-exists-p "/proc/self/fd/0"))
  (skip-unless (valsi-server-test--emacs-program))
  (let* ((uri "café-\U0001F600- .md")
         (text "# Café \U0001F600 x\n- [ ] T1 naïve\n")
         (input (encode-coding-string
                 (concat
                  (json-serialize
                   (list :jsonrpc "2.0" :id 1 :method "artifact/didOpen"
                         :params (list :uri uri :text text)))
                  "\n"
                  (json-serialize
                   (list :jsonrpc "2.0" :id 2 :method "artifact/symbols"
                         :params (list :uri uri)))
                  "\n")
                 'utf-8-unix)))
    (dolist (environment '(nil ("LC_ALL=C" "LANG=C")))
      (let ((bytes (valsi-server-test--stdio-bytes input environment)))
        (should-not (multibyte-string-p bytes))
        ;; é is C3 A9, U+1F600 is F0 9F 98 80 and U+2028 is E2 80 A8; never
        ;; Emacs's internal raw-byte forms such as C1 83 C0 A9.
        (should (string-search
                 "caf\303\251-\360\237\230\200-\342\200\250.md" bytes))
        (should (string-search "Caf\303\251 \360\237\230\200" bytes))
        (should-not (string-match-p "[\300\301]" bytes))
        ;; U+2028 is data, so there are exactly two LF-terminated records.
        (should (= 2 (cl-count ?\n bytes)))
        (let ((records (split-string
                        (decode-coding-string bytes 'utf-8-unix) "\n" t)))
          (should (equal uri
                         (plist-get
                          (plist-get (json-parse-string
                                      (car records) :object-type 'plist)
                                     :result)
                          :uri))))))))

(provide 'valsi-server-test)
;;; valsi-server-test.el ends here
