;;; nsm.el --- Network Security Manager

;; Copyright (C) 2014 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;; Keywords: encryption, security, network

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(require 'cl-lib)

(defvar nsm-permanent-host-settings nil)
(defvar nsm-temporary-host-settings nil)

(defgroup nsm nil
  "Network Security Manager"
  :version "25.1"
  :group 'comm)

(defcustom network-security-level 'low
  "How secure the network should be.
If a potential problem with the security of the network
connection is found, the user is asked to give input into how the
connection should be handled.

The following values are possible:

`low': Absolutely no checks are performed.

`medium': This is the default level, and the following things will
be prompted for.

* invalid, self-signed or otherwise unverifiable certificates
* whether a previously accepted unverifiable certificate has changed
* when a connection that was previously protected by STARTTLS is
  now unencrypted

`high': In addition to the above.

* any certificate that changes its public key

`paranoid': In addition to the above.

* any new certificate that you haven't seen before"
  :version "25.1"
  :group 'nsm
  :type '(choice (const :tag "Low" low)
		 (const :tag "Medium" medium)
		 (const :tag "High" high)
		 (const :tag "Paranoid" paranoid)))

(defcustom nsm-settings-file (expand-file-name "network-security.data"
						 user-emacs-directory)
  "The file the security manager settings will be stored in."
  :version "25.1"
  :group 'nsm
  :type 'file)

(defcustom nsm-save-host-names nil
  "If non-nil, always save host names in the structures in `nsm-settings-file'.
By default, only hosts that have exceptions have their names
stored in plain text."
  :version "25.1"
  :group 'nsm
  :type 'boolean)

(defvar nsm-noninteractive nil
  "If non-nil, the connection is opened in a non-interactive context.
This means that no queries should be performed.")

(defun nsm-verify-connection (process host port &optional
				      save-fingerprint warn-unencrypted)
  "Verify the security status of PROCESS that's connected to HOST:PORT.
If PROCESS is a gnutls connection, the certificate validity will
be examined.  If it's a non-TLS connection, it may be compared
against previous connections.  If the function determines that
there is something odd about the connection, the user will be
queried about what to do about it.

The process it returned if everything is OK, and otherwise, the
process will be deleted and nil is returned.

If SAVE-FINGERPRINT, always save the fingerprint of the
server (if the connection is a TLS connection).  This is useful
to keep track of the TLS status of STARTTLS servers.

If WARN-UNENCRYPTED, query the user if the connection is
unencrypted."
  (if (eq network-security-level 'low)
      process
    (let* ((status (gnutls-peer-status process))
	   (id (nsm-id host port))
	   (settings (nsm-host-settings id)))
      (cond
       ((not (process-live-p process))
	nil)
       ((not status)
	;; This is a non-TLS connection.
	(nsm-check-plain-connection process host port settings
				    warn-unencrypted))
       (t
	(let ((process
	       (nsm-check-tls-connection process host port status settings)))
	  (when (and process save-fingerprint
		     (null (nsm-host-settings id)))
	    (nsm-save-host host port status 'fingerprint 'always))
	  process))))))

(defun nsm-check-tls-connection (process host port status settings)
  (let ((warnings (plist-get status :warnings)))
    (cond

     ;; The certificate validated, but perhaps we want to do
     ;; certificate pinning.
     ((null warnings)
      (cond
       ((< (nsm-level network-security-level) (nsm-level 'high))
	process)
       ;; The certificate is fine, but if we're paranoid, we might
       ;; want to check whether it's changed anyway.
       ((and (>= (nsm-level network-security-level) (nsm-level 'high))
	     (not (nsm-fingerprint-ok-p host port status settings)))
	(delete-process process)
	nil)
       ;; We haven't seen this before, and we're paranoid.
       ((and (eq network-security-level 'paranoid)
	     (null settings)
	     (not (nsm-new-fingerprint-ok-p host port status)))
	(delete-process process)
	nil)
       ((>= (nsm-level network-security-level) (nsm-level 'high))
	;; Save the host fingerprint so that we can check it the
	;; next time we connect.
	(nsm-save-host host port status 'fingerprint 'always)
	process)
       (t
	process)))

     ;; The certificate did not validate.
     ((not (equal network-security-level 'low))
      ;; We always want to pin the certificate of invalid connections
      ;; to track man-in-the-middle or the like.
      (if (not (nsm-fingerprint-ok-p host port status settings))
	  (progn
	    (delete-process process)
	    nil)
	;; We have a warning, so query the user.
	(if (and (not (nsm-warnings-ok-p status settings))
		 (not (nsm-query
		       host port status 'conditions
		       "The TLS connection to %s:%s is insecure\nfor the following reason%s:\n\n%s"
		       host port
		       (if (> (length warnings) 1)
			   "s" "")
		       (mapconcat #'gnutls-peer-status-warning-describe
                                  warnings
                                  "\n"))))
	    (progn
	      (delete-process process)
	      nil)
	  process))))))

(defun nsm-fingerprint (status)
  (plist-get (plist-get status :certificate) :public-key-id))

(defun nsm-fingerprint-ok-p (host port status settings)
  (let ((did-query nil))
    (if (and settings
	     (not (eq (plist-get settings :fingerprint) :none))
	     (not (equal (nsm-fingerprint status)
			 (plist-get settings :fingerprint)))
	     (not
	      (setq did-query
		    (nsm-query
		     host port status 'fingerprint
		     "The fingerprint for the connection to %s:%s has changed from\n%s to\n%s"
		     host port
		     (plist-get settings :fingerprint)
		     (nsm-fingerprint status)))))
	;; Not OK.
	nil
      (when did-query
	;; Remove any exceptions that have been set on the previous
	;; certificate.
	(plist-put settings :conditions nil))
      t)))

(defun nsm-new-fingerprint-ok-p (host port status)
  (nsm-query
   host port nil 'fingerprint
   "The fingerprint for the connection to %s:%s is new:\n%s"
   host port
   (nsm-fingerprint status)))

(defun nsm-check-plain-connection (process host port settings warn-unencrypted)
  ;; If this connection used to be TLS, but is now plain, then it's
  ;; possible that we're being Man-In-The-Middled by a proxy that's
  ;; stripping out STARTTLS announcements.
  (cond
   ((and (plist-get settings :fingerprint)
	 (not (eq (plist-get settings :fingerprint) :none))
	 (not
	  (nsm-query
	   host port nil 'conditions
	   "The connection to %s:%s used to be an encrypted\nconnection, but is now unencrypted.  This might mean that there's a\nman-in-the-middle tapping this connection."
	   host port)))
    (delete-process process)
    nil)
   ((and warn-unencrypted
	 (not (memq :unencrypted (plist-get settings :conditions)))
	 (not (nsm-query
	       host port nil 'conditions
	       "The connection to %s:%s is unencrypted."
	       host port)))
    (delete-process process)
    nil)
   (t
    process)))

(defun nsm-query (host port status what message &rest args)
  ;; If there is no user to answer queries, then say `no' to everything.
  (if (or noninteractive
	  nsm-noninteractive)
      nil
    (let ((response
	   (condition-case nil
	       (nsm-query-user message args (nsm-format-certificate status))
	     ;; Make sure we manage to close the process if the user hits
	     ;; `C-g'.
	     (quit 'no)
	     (error 'no))))
      (if (eq response 'no)
	  nil
	(nsm-save-host host port status what response)
	t))))

(defun nsm-query-user (message args cert)
  (let ((buffer (get-buffer-create "*Network Security Manager*")))
    (with-help-window buffer
      (with-current-buffer buffer
	(erase-buffer)
	(when (> (length cert) 0)
	  (insert cert "\n"))
	(insert (apply 'format message args))))
    (let ((responses '((?n . no)
		       (?s . session)
		       (?a . always)))
	  (prefix "")
	  response)
      (while (not response)
	(setq response
	      (cdr
	       (assq (downcase
		      (read-char
		       (concat prefix
			       "Continue connecting? (No, Session only, Always)")))
		     responses)))
	(unless response
	  (ding)
	  (setq prefix "Invalid choice.  ")))
      (kill-buffer buffer)
      ;; If called from a callback, `read-char' will insert things
      ;; into the pending input.  Clear that.
      (clear-this-command-keys)
      response)))

(defun nsm-save-host (host port status what permanency)
  (let* ((id (nsm-id host port))
	 (saved
	  (list :id id
		:fingerprint (or (nsm-fingerprint status)
				 ;; Plain connection.
				 :none))))
    (when (or (eq what 'conditions)
	      nsm-save-host-names)
      (nconc saved (list :host (format "%s:%s" host port))))
    ;; We either want to save/update the fingerprint or the conditions
    ;; of the certificate/unencrypted connection.
    (when (eq what 'conditions)
      (nconc saved (list :host (format "%s:%s" host port)))
      (cond
       ((not status)
	(nconc saved `(:conditions (:unencrypted))))
       ((plist-get status :warnings)
	(nconc saved
	       `(:conditions ,(plist-get status :warnings))))))
    (if (eq permanency 'always)
	(progn
	  (nsm-remove-temporary-setting id)
	  (nsm-remove-permanent-setting id)
	  (push saved nsm-permanent-host-settings)
	  (nsm-write-settings))
      (nsm-remove-temporary-setting id)
      (push saved nsm-temporary-host-settings))))

(defun nsm-write-settings ()
  (with-temp-file nsm-settings-file
    (insert "(\n")
    (dolist (setting nsm-permanent-host-settings)
      (insert " ")
      (prin1 setting (current-buffer))
      (insert "\n"))
    (insert ")\n")))

(defun nsm-read-settings ()
  (setq nsm-permanent-host-settings
	(with-temp-buffer
	  (insert-file-contents nsm-settings-file)
	  (goto-char (point-min))
	  (ignore-errors (read (current-buffer))))))

(defun nsm-id (host port)
  (concat "sha1:" (sha1 (format "%s:%s" host port))))

(defun nsm-host-settings (id)
  (when (and (not nsm-permanent-host-settings)
	     (file-exists-p nsm-settings-file))
    (nsm-read-settings))
  (let ((result nil))
    (dolist (elem (append nsm-temporary-host-settings
			  nsm-permanent-host-settings))
      (when (and (not result)
		 (equal (plist-get elem :id) id))
	(setq result elem)))
    result))

(defun nsm-warnings-ok-p (status settings)
  (null (cl-intersection
         (plist-get settings :conditions)
         (plist-get status :warnings))))

(defun nsm-remove-permanent-setting (id)
  (setq nsm-permanent-host-settings
	(cl-delete-if
	 (lambda (elem)
	   (equal (plist-get elem :id) id))
	 nsm-permanent-host-settings)))

(defun nsm-remove-temporary-setting (id)
  (setq nsm-temporary-host-settings
	(cl-delete-if
	 (lambda (elem)
	   (equal (plist-get elem :id) id))
	 nsm-temporary-host-settings)))

(defun nsm-format-certificate (status)
  (let ((cert (plist-get status :certificate)))
    (when cert
      (with-temp-buffer
	(insert
	 "Certificate information\n"
	 "Issued by:"
	 (nsm-certificate-part (plist-get cert :issuer) "CN" t) "\n"
	 "Issued to:"
	 (or (nsm-certificate-part (plist-get cert :subject) "O")
	     (nsm-certificate-part (plist-get cert :subject) "OU" t))
	 "\n"
	 "Hostname:"
	 (nsm-certificate-part (plist-get cert :subject) "CN" t) "\n")
	(when (and (plist-get cert :public-key-algorithm)
		   (plist-get cert :signature-algorithm))
	  (insert
	   "Public key:" (plist-get cert :public-key-algorithm)
	   ", signature: " (plist-get cert :signature-algorithm) "\n"))
	(when (plist-get cert :certificate-security-level)
	  (insert
	   "Security level:"
	   (propertize (plist-get cert :certificate-security-level)
		       'face 'bold)
	   "\n"))
	(insert
	 "Valid:From " (plist-get cert :valid-from)
	 " to " (plist-get cert :valid-to) "\n\n")
	(goto-char (point-min))
	(while (re-search-forward "^[^:]+:" nil t)
	  (insert (make-string (- 20 (current-column)) ? )))
	(buffer-string)))))

(defun nsm-certificate-part (string part &optional full)
  (let ((part (cadr (assoc part (nsm-parse-subject string)))))
    (cond
     (part part)
     (full string)
     (t nil))))

(defun nsm-parse-subject (string)
  (with-temp-buffer
    (insert string)
    (goto-char (point-min))
    (let ((start (point))
	  (result nil))
      (while (not (eobp))
	(push (replace-regexp-in-string
	       "[\\]\\(.\\)" "\\1"
	       (buffer-substring start
				 (if (re-search-forward "[^\\]," nil 'move)
				     (1- (point))
				   (point))))
	      result)
	(setq start (point)))
      (mapcar
       (lambda (elem)
	 (let ((pos (cl-position ?= elem)))
	   (if pos
	       (list (substring elem 0 pos)
		     (substring elem (1+ pos)))
	     elem)))
       (nreverse result)))))

(defun nsm-level (symbol)
  "Return a numerical level for SYMBOL for easier comparison."
  (cond
   ((eq symbol 'low) 0)
   ((eq symbol 'medium) 1)
   ((eq symbol 'high) 2)
   (t 3)))

(provide 'nsm)

;;; nsm.el ends here
