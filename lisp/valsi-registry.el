;;; valsi-registry.el --- Grammar-plugin registry for Valsi -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The grammar-plugin registry -- the AAP `grammar/register' (which also
;; hot-reloads) / `grammar/describe' surface, realized in-process.  Each
;; grammar declares:
;;
;;   :id          symbol, unique
;;   :name        human label
;;   :evidence    standardized | converging | emergent
;;   :match       (function URI TEXT) -> score (higher wins), for auto-detect;
;;                URI is the document name, TEXT its content string
;;   :parse       (function CONTENT) -> root `valsi-node' with 0-based
;;                offsets into the CONTENT string
;;   :font-lock   font-lock keyword list (or function BUFFER -> keywords)
;;   :capabilities  list of action symbols, OR (function ROOT) -> list
;;                  (the degradation ladder, advertised per document)
;;   :commands    alist (ACTION . COMMAND-SYMBOL) dispatched by the client
;;
;; Registering or reloading a grammar takes effect immediately -- no restart
;; (the liveness / hot-reload invariant).

;;; Code:

(require 'cl-lib)
(require 'valsi-node)
(require 'valsi-parse)

(defvar valsi-registry--table (make-hash-table :test 'eq)
  "Map of grammar id (symbol) -> grammar spec plist.")

(defvar valsi-registry-hook nil
  "Run with the grammar id after a grammar is (re)registered.")

(defvar valsi-registry-generation 0
  "Revision of grammar definitions, for invalidating derived caches.")

;;;; Bounding client-declared regexps
;;
;; Emacs cannot interrupt a running regexp match (timers do not run inside
;; the matcher in batch), so wire-registered grammars are bounded by cost
;; analysis instead of a timeout.  For a regexp R of length |R| matched
;; against N characters by the backtracking matcher:
;;
;; - Registration rejects back references and any repeated group that
;;   contains a quantifier or an alternative (the exponential class), so
;;   every unbounded repetition (`*', `+', `\{M,\}') applies to one
;;   fixed-width atom and has at most N+1 ways to stop.
;; - Such a repetition before the rest R' of the pattern costs at most
;;   (N+1)(1 + cost(R')); `?', an alternative of B branches and a bounded
;;   interval multiply the cost by their number of choices; any other
;;   atom adds one step.  By induction one match attempt costs at most
;;   (|R|+1) * F * (N+1)^Q steps, where Q counts the unbounded repetitions
;;   (those of all branches of an alternative added up) and F is the
;;   product of the finite choice counts.
;; - An unanchored search makes up to N+1 attempts, so the degree is
;;   D = Q + 1.  It is D = Q when R starts with \\=\\`, or with ^ for a
;;   recognizer, whose subject is one line: the other attempts then fail
;;   on their first step, adding only N.
;;
;; Each regexp thus gets its own input limit, the largest N up to
;; `valsi-registry-declarative-match-limit' with (|R|+1) F (N+1)^D within
;; `valsi-registry-declarative-step-budget'.  A regexp whose limit would
;; fall below `valsi-registry-declarative-min-limit' is rejected at
;; registration, which admits at most two unbounded repetitions counting
;; the search loop (worst case O(N^2)).  So a*a*a*a*a*b (D = 6) is
;; rejected while .*x and ^\\(#+\\) \\(.*\\)$ keep the full limit.  Longer
;; input is not matched: `textRegexp' sees a prefix, a longer URI does not
;; match, and a longer line resolves less detail.
;;
;; One request may run many bounded matches (lines times recognizers, and
;; one `textRegexp' per declared grammar), so declarative matching also
;; stops after `valsi-registry-declarative-time-budget' seconds of the
;; request.  A match only starts before that deadline, so a request spends
;; at most the budget plus one bounded match in declared regexps.

(defconst valsi-registry-declarative-match-limit 2000
  "Longest string any client-declared regexp is matched against.
A complex regexp gets a smaller limit from `valsi-registry--regexp-limit'.")

(defconst valsi-registry-declarative-min-limit 256
  "Shortest input limit a client-declared regexp may be left with.
Registration rejects a regexp whose step budget allows less.")

(defconst valsi-registry-declarative-step-budget 1e8
  "Worst-case backtracking steps for one client-declared regexp match.
Far below a second on current hardware.")

(defconst valsi-registry-declarative-time-budget 1.0
  "Seconds of client-declared regexp matching allowed per request.
After the deadline declared grammars stop matching: detection scores them
0 and their parsers resolve no further lines.")

(defvar valsi-registry--declarative-deadline nil
  "The `float-time' after which declarative matching stops, or nil.")

(defmacro valsi-registry-with-declarative-deadline (&rest body)
  "Run BODY under a deadline for client-declared regexp matching.
An enclosing deadline is kept, so a whole request shares one budget."
  (declare (indent 0) (debug t))
  `(let ((valsi-registry--declarative-deadline
          (or valsi-registry--declarative-deadline
              (+ (float-time) valsi-registry-declarative-time-budget))))
     ,@body))

(defun valsi-registry--declarative-time-left-p ()
  "Return non-nil unless the declarative matching deadline has passed."
  (or (null valsi-registry--declarative-deadline)
      (< (float-time) valsi-registry--declarative-deadline)))

;;;; Registration (grammar/register, grammar/reload)

(defun valsi-registry-register (spec)
  "Register grammar SPEC (a plist).  Overwrites any grammar with the same id.
Takes effect immediately (hot-reload); returns the id."
  (let ((id (plist-get spec :id)))
    (unless id (error "Grammar spec has no :id"))
    (puthash id spec valsi-registry--table)
    (cl-incf valsi-registry-generation)
    (run-hook-with-args 'valsi-registry-hook id)
    id))

(defalias 'valsi-registry-reload #'valsi-registry-register
  "Reload a grammar SPEC in place (alias of `valsi-registry-register').")

(defun valsi-registry-register-declaration (declaration)
  "Compile and register JSON-safe grammar DECLARATION.
Unlike the internal plugin API accepted by `valsi-registry-register',
DECLARATION contains data rather than executable functions.  Its `:match'
object may contain `:uriSuffix', `:uriRegexp', `:textRegexp', and `:score'.
Its `:recognizers' array contains line recognizers with `:type', `:regexp',
optional `:confidence', and optional capture-index `:properties'."
  (let* ((id (valsi-registry--declaration-symbol
              (plist-get declaration :id) "grammar id"))
         (evidence (valsi-registry--declaration-symbol
                    (or (plist-get declaration :evidence) "emergent")
                    "evidence"))
         (match-decl (plist-get declaration :match))
         (recognizers (append (plist-get declaration :recognizers) nil))
         (caps (mapcar (lambda (cap)
                         (valsi-registry--declaration-symbol cap "capability"))
                       (append (plist-get declaration :capabilities) nil)))
         (root-type (valsi-registry--declaration-symbol
                     (or (plist-get declaration :rootType) "document")
                     "root type")))
    (unless (memq evidence '(standardized converging emergent))
      (error "Grammar declaration has invalid evidence tier: %S" evidence))
    (valsi-registry--validate-declaration match-decl recognizers)
    (valsi-registry-register
     (list :id id
           :name (or (plist-get declaration :name) (symbol-name id))
           :evidence evidence
           :match (valsi-registry--declarative-matcher match-decl)
           :parse (valsi-registry--declarative-parser id root-type recognizers)
           :capabilities caps
           :commands nil
           :declaration declaration))))

(defun valsi-registry--declaration-symbol (value field)
  "Coerce string or symbol VALUE to a symbol, identifying invalid FIELD."
  (cond ((symbolp value) value)
        ((and (stringp value) (not (string-empty-p value))) (intern value))
        (t (error "Grammar declaration has invalid %s: %S" field value))))

(defun valsi-registry--validate-regexp (regexp field &optional line)
  "Validate REGEXP from FIELD, signaling a useful registration error.
LINE non-nil means REGEXP is only matched against single lines."
  (when regexp
    (unless (stringp regexp)
      (error "Grammar declaration %s must be a string" field))
    (condition-case err
        (string-match-p regexp "")
      (invalid-regexp
       (error "Grammar declaration has invalid %s: %s"
              field (error-message-string err))))
    (let ((risk (valsi-registry--regexp-risk regexp line)))
      (when risk
        (error "Grammar declaration %s is rejected (%s): %s"
               field risk regexp)))))

(defun valsi-registry--regexp-analysis (regexp &optional line)
  "Return (RISK DEGREE FACTOR) for client-supplied REGEXP.
RISK names an exponential construct in REGEXP, or is nil.  DEGREE counts
the unbounded repetitions, plus one for the search loop unless REGEXP
starts with \\=\\` or, when LINE is non-nil, with ^.  FACTOR is the
product of the choice counts of `?', alternatives and bounded intervals.
The cost argument is in the commentary before
`valsi-registry-declarative-match-limit'."
  (let ((i 0) (len (length regexp))
        ;; One frame per open group: [HAS-QUANTIFIER BRANCHES].
        (frames (list (vector nil 1)))
        (degree (if (or (string-prefix-p "\\`" regexp)
                        (and line (string-prefix-p "^" regexp)))
                    0 1))
        (factor 1)
        risk)
    (cl-flet ((mark () (aset (car frames) 0 t))
              (interval-at (pos)
                (and (< (1+ pos) len)
                     (eq (aref regexp pos) ?\\)
                     (eq (aref regexp (1+ pos)) ?{))))
      (while (and (< i len) (not risk))
        (let ((c (aref regexp i)))
          (cond
           ((eq c ?\[)
            ;; Skip a bracket expression; a leading `]' is literal.
            (setq i (1+ i))
            (when (and (< i len) (eq (aref regexp i) ?^)) (setq i (1+ i)))
            (when (and (< i len) (eq (aref regexp i) ?\])) (setq i (1+ i)))
            (while (and (< i len) (not (eq (aref regexp i) ?\])))
              (if (and (eq (aref regexp i) ?\[) (< (1+ i) len)
                       (eq (aref regexp (1+ i)) ?:))
                  (setq i (+ 2 (or (string-search ":]" regexp (+ i 2))
                                   len)))
                (setq i (1+ i))))
            (setq i (1+ i)))
           ((and (eq c ?\\) (< (1+ i) len))
            (let ((d (aref regexp (1+ i))))
              (setq i (+ i 2))
              (cond
               ((eq d ?\()
                (push (vector nil 1) frames)
                ;; Shy and explicitly numbered groups: \(?: and \(?N:.
                (when (and (< i len) (eq (aref regexp i) ??))
                  (setq i (1+ i))
                  (while (and (< i len) (<= ?0 (aref regexp i) ?9))
                    (setq i (1+ i)))
                  (when (and (< i len) (eq (aref regexp i) ?:))
                    (setq i (1+ i)))))
               ((eq d ?|)
                (aset (car frames) 1 (1+ (aref (car frames) 1))))
               ((eq d ?{)
                (let* ((close (or (string-search "\\}" regexp i) len))
                       (body (substring regexp i close))
                       (comma (string-search "," body))
                       (lo (string-to-number (substring body 0 comma)))
                       (hi (and comma
                                (< (1+ comma) (length body))
                                (string-to-number
                                 (substring body (1+ comma))))))
                  (setq i (+ 2 close))
                  (mark)
                  (cond ((not comma))   ; \{M\} has a single choice.
                        ;; A wide interval is as costly as an unbounded one.
                        ((or (null hi) (> (- hi lo) 15))
                         (setq degree (1+ degree)))
                        ((> hi lo)
                         (setq factor (* factor (1+ (- hi lo))))))))
               ((and (>= d ?1) (<= d ?9))
                (setq risk "back reference"))
               ((memq d '(?s ?S ?c ?C ?_))
                ;; Syntax and category classes and symbol boundaries take
                ;; an argument character.
                (setq i (1+ i)))
               ((eq d ?\))
                (let ((inner (pop frames)))
                  (unless frames (setq frames (list (vector nil 1))))
                  (setq factor (* factor (aref inner 1)))
                  (when (or (aref inner 0) (> (aref inner 1) 1))
                    (when (or (and (< i len) (memq (aref regexp i) '(?* ?+)))
                              (interval-at i))
                      (setq risk (concat "repeated group with a quantifier"
                                         " or alternative")))
                    (mark)))))))
           ((memq c '(?* ?+))
            (mark)
            (setq degree (1+ degree)
                  i (1+ i))
            ;; The non-greedy modifier is not another `?'.
            (when (and (< i len) (eq (aref regexp i) ??)) (setq i (1+ i))))
           ((eq c ??)
            (mark)
            (setq factor (* 2 factor)
                  i (1+ i))
            (when (and (< i len) (eq (aref regexp i) ??)) (setq i (1+ i))))
           (t (setq i (1+ i)))))))
    (list risk degree factor)))

(defun valsi-registry--regexp-limit (regexp &optional line)
  "Return the longest input client REGEXP may be matched against.
This is the largest N up to `valsi-registry-declarative-match-limit' for
which the worst-case cost (|R|+1) F (N+1)^D stays within
`valsi-registry-declarative-step-budget', with D and F from
`valsi-registry--regexp-analysis' (which see for LINE).  It is negative
when even the empty string exceeds the budget."
  (pcase-let* ((`(,_risk ,degree ,factor)
                (valsi-registry--regexp-analysis regexp line))
               (per-path (* (float (1+ (length regexp))) factor))
               (cap valsi-registry-declarative-match-limit))
    (cond ((> per-path valsi-registry-declarative-step-budget) -1)
          ((zerop degree) cap)
          (t (min cap
                  (1- (floor (expt (/ valsi-registry-declarative-step-budget
                                      per-path)
                                   (/ 1.0 degree)))))))))

(defun valsi-registry--regexp-risk (regexp &optional line)
  "Return why client-supplied REGEXP is too costly to run, or nil.
Back references and repeated groups containing a quantifier or an
alternative, as in \\(a*\\)*b or \\(a\\|aa\\)*b, backtrack exponentially.
Polynomial patterns such as a*a*a*a*a*b are rejected when
`valsi-registry--regexp-limit' leaves them less input than
`valsi-registry-declarative-min-limit'.  LINE is as for
`valsi-registry--regexp-analysis'."
  (or (car (valsi-registry--regexp-analysis regexp line))
      (let ((limit (valsi-registry--regexp-limit regexp line)))
        (when (< limit valsi-registry-declarative-min-limit)
          (format (concat "too many unbounded or optional repetitions;"
                          " its worst-case cost allows only %d characters"
                          " of input; anchor it with \\` or ^ or simplify it")
                  (max limit 0))))))

(defun valsi-registry--validate-declaration (match-decl recognizers)
  "Validate declarative MATCH-DECL and line RECOGNIZERS."
  (unless (listp match-decl)
    (error "Grammar declaration :match must be an object"))
  (unless (cl-some (lambda (key) (plist-get match-decl key))
                   '(:uriSuffix :uriRegexp :textRegexp))
    (error "Grammar declaration :match needs a URI or text predicate"))
  (let ((suffix (plist-get match-decl :uriSuffix)))
    (when (and suffix (not (stringp suffix)))
      (error "Grammar declaration :match.uriSuffix must be a string")))
  (valsi-registry--validate-regexp (plist-get match-decl :uriRegexp)
                                  ":match.uriRegexp")
  (valsi-registry--validate-regexp (plist-get match-decl :textRegexp)
                                  ":match.textRegexp")
  (unless (numberp (or (plist-get match-decl :score) 1))
    (error "Grammar declaration :match.score must be a number"))
  (dolist (recognizer recognizers)
    (valsi-registry--declaration-symbol (plist-get recognizer :type)
                                       "recognizer type")
    (unless (stringp (plist-get recognizer :regexp))
      (error "Grammar declaration recognizers need a regexp string"))
    (valsi-registry--validate-regexp (plist-get recognizer :regexp)
                                    ":recognizers[].regexp" t)
    (let ((confidence
           (valsi-registry--declaration-symbol
            (or (plist-get recognizer :confidence) "exact")
            "recognizer confidence"))
          (properties (plist-get recognizer :properties)))
      (unless (memq confidence '(exact loose))
        (error "Grammar recognizer confidence must be exact or loose"))
      (while properties
        (unless (and (keywordp (car properties))
                     (integerp (cadr properties))
                     (>= (cadr properties) 0))
          (error "Grammar recognizer properties must map names to capture indices"))
        (setq properties (cddr properties)))))
  t)

(defun valsi-registry--declarative-matcher (declaration)
  "Return a pure matcher function compiled from match DECLARATION.
Declared regexps see bounded input and stop matching after the request's
declarative deadline; see `valsi-registry-declarative-match-limit'."
  (let* ((suffix (plist-get declaration :uriSuffix))
         (uri-re (plist-get declaration :uriRegexp))
         (uri-limit (and uri-re (valsi-registry--regexp-limit uri-re)))
         (text-re (plist-get declaration :textRegexp))
         (text-limit (and text-re (valsi-registry--regexp-limit text-re)))
         (score (or (plist-get declaration :score) 1)))
    (lambda (uri text)
      (valsi-registry-with-declarative-deadline
        (if (or (and suffix (string-suffix-p suffix (or uri "")))
                (and uri-re
                     (<= (length uri) uri-limit)
                     (valsi-registry--declarative-time-left-p)
                     (string-match-p uri-re (or uri "")))
                (and text-re
                     (valsi-registry--declarative-time-left-p)
                     (string-match-p
                      text-re
                      (let ((text (or text "")))
                        (if (> (length text) text-limit)
                            (substring text 0 text-limit)
                          text)))))
            score
          0)))))

(defun valsi-registry--declarative-parser (grammar-id root-type recognizers)
  "Return a parser for GRAMMAR-ID, ROOT-TYPE, and line RECOGNIZERS.
A recognizer skips lines longer than its `valsi-registry--regexp-limit',
and no recognizer runs after the request's declarative deadline; those
lines resolve less detail."
  (let ((limits (mapcar (lambda (recognizer)
                          (let ((regexp (plist-get recognizer :regexp)))
                            (if regexp (valsi-registry--regexp-limit regexp t)
                              -1)))
                        recognizers)))
    (lambda (content)
      (valsi-registry-with-declarative-deadline
        (valsi-parse-in-content
         content
         (lambda ()
           (let ((root (valsi-node-create :type root-type
                                         :beg (point-min) :end (point-max)
                                         :recognizer grammar-id)))
             (dolist (line (valsi-parse-lines (current-buffer)))
               (cl-loop
                for recognizer in recognizers
                for limit in limits
                do
                (let ((regexp (plist-get recognizer :regexp))
                      (text (valsi-line-text line)))
                  (when (and regexp
                             (<= (length text) limit)
                             (valsi-registry--declarative-time-left-p)
                             (string-match regexp text))
                    (valsi-node-add-child
                     root
                     (valsi-node-create
                      :type (valsi-registry--declaration-symbol
                             (plist-get recognizer :type) "recognizer type")
                      :beg (valsi-line-beg line) :end (valsi-line-end line)
                      :confidence
                      (valsi-registry--declaration-symbol
                       (or (plist-get recognizer :confidence) "exact")
                       "recognizer confidence")
                      :recognizer grammar-id
                      :props (valsi-registry--declarative-props
                              (plist-get recognizer :properties) text)))))))
             root)))))))

(defun valsi-registry--declarative-props (properties text)
  "Extract capture-index PROPERTIES from the current match against TEXT."
  (let (out)
    (while properties
      (let ((key (car properties))
            (capture (cadr properties)))
        (when (and (integerp capture) (match-beginning capture))
          (setq out (plist-put out key (match-string capture text)))))
      (setq properties (cddr properties)))
    out))

(defun valsi-registry-unregister (id)
  "Remove grammar ID from the registry."
  (remhash id valsi-registry--table)
  (cl-incf valsi-registry-generation))

(defun valsi-registry-get (id)
  "Return the spec for grammar ID, or nil."
  (gethash id valsi-registry--table))

(defun valsi-registry-all ()
  "Return a list of all registered grammar ids."
  (let (ids) (maphash (lambda (k _v) (push k ids)) valsi-registry--table)
       (nreverse ids)))

(defun valsi-registry-describe (id)
  "Return a human-readable description plist for grammar ID (grammar/describe)."
  (let ((s (valsi-registry-get id)))
    (when s
      (list :id id
            :name (plist-get s :name)
            :evidence (plist-get s :evidence)
            :commands (mapcar #'car (plist-get s :commands))))))

;;;; Detection (which grammar owns this document)

(defun valsi-registry-detect (uri text)
  "Return the id of the best-matching grammar for URI + TEXT.
URI is a document identifier (path/name) and TEXT is its content.  Detection
is a pure function of these two -- no live buffer -- except that declared
grammars score 0 once `valsi-registry-declarative-time-budget' is spent.
Falls back to `generic' when nothing scores above zero."
  (valsi-registry-with-declarative-deadline
    (let ((best 'generic) (best-score 0))
      (dolist (id (valsi-registry-all))
        (let* ((spec (valsi-registry-get id))
               (match (plist-get spec :match))
               (score (if match
                          (condition-case nil
                              (or (funcall match uri text) 0)
                            (error 0))
                        0)))
          (when (> score best-score)
            (setq best id best-score score))))
      best)))

;;;; Parse + capability advertisement

(defun valsi-registry-parse-content (id content)
  "Parse CONTENT (a string) with grammar ID, returning the offset-based root.
The result is buffer-independent (0-based offsets into CONTENT)."
  (let* ((spec (valsi-registry-get id))
         (parse (plist-get spec :parse)))
    (if parse
        (funcall parse content)
      (valsi-registry--parse-generic content))))

(defun valsi-registry-capabilities (id root)
  "Return the list of action symbols grammar ID supports for ROOT.
This is the per-document degradation-ladder advertisement."
  (let* ((spec (valsi-registry-get id))
         (caps (plist-get spec :capabilities)))
    (cond ((functionp caps) (funcall caps root))
          ((listp caps) caps)
          (t nil))))

(defun valsi-registry-command (id action)
  "Return the command symbol for ACTION in grammar ID, or nil."
  (let ((spec (valsi-registry-get id)))
    (cdr (assq action (plist-get spec :commands)))))

;;;; The generic-markdown grammar (rung 1: outline / narrowing only)

(defun valsi-registry--parse-generic (content)
  "Parse CONTENT into a heading outline tree (rung-1 generic markdown)."
  (valsi-parse-in-content
   content
   (lambda ()
     (let ((root (valsi-node-create :type 'document
                                   :beg (point-min) :end (point-max)
                                   :recognizer 'generic))
           (stack nil))                  ; list of (level . node)
       (dolist (line (valsi-parse-lines (current-buffer)))
         (let ((h (valsi-parse-heading (valsi-line-text line))))
           (if h
               (let ((node (valsi-node-create
                            :type 'heading
                            :beg (valsi-line-beg line) :end (valsi-line-end line)
                            :recognizer 'generic
                            :props (list :level (car h) :title (cdr h)))))
                 (while (and stack (>= (caar stack) (car h)))
                   (pop stack))
                 (if stack
                     (valsi-node-add-child (cdar stack) node)
                   (valsi-node-add-child root node))
                 (push (cons (car h) node) stack)))))
       root))))

(defun valsi-registry-init-generic ()
  "Register the fallback generic-markdown grammar."
  (valsi-registry-register
   (list :id 'generic
         :name "Generic Markdown"
         :evidence 'standardized
         :match (lambda (_uri _text) 0)
         :parse #'valsi-registry--parse-generic
         :capabilities '(outline narrow)
         :commands nil)))

;; The bundled grammar plugins require this file, so they are loaded at
;; runtime here and only declared for the byte-compiler.
(declare-function valsi-plan-register "valsi-plan")
(declare-function valsi-instruction-register "valsi-instruction")
(declare-function valsi-promptfile-register "valsi-promptfile")
(declare-function valsi-memory-register "valsi-memory")
(declare-function valsi-changelog-register "valsi-changelog")
(declare-function valsi-decision-register "valsi-decision")
(declare-function valsi-overview-register "valsi-overview")

(defun valsi-registry-register-bundled ()
  "Load and register the generic grammar and all bundled grammar plugins.
The single registration site shared by the in-process client
\(`valsi-init') and the standalone server (`valsi-server-init')."
  (dolist (feature '(valsi-plan valsi-instruction valsi-promptfile valsi-memory
                     valsi-changelog valsi-decision valsi-overview))
    (require feature))
  (valsi-registry-init-generic)
  (valsi-plan-register)
  (valsi-instruction-register)
  (valsi-promptfile-register)
  (valsi-memory-register)
  (valsi-changelog-register)
  (valsi-decision-register)
  (valsi-overview-register))

(provide 'valsi-registry)
;;; valsi-registry.el ends here
