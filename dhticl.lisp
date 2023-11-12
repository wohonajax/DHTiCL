(in-package :dhticl)

;;;; TODO: general interface
(defvar *settings-location*
  (merge-pathnames ".dhticlrc" (user-homedir-pathname)))

(defvar *hashes* (list)
  "The list of info_hashes the DHT program will use.")

;;; TODO: sanitize settings
(defun load-settings ()
  "Loads settings."
  (let ((file (probe-file *settings-location*)))
    (when file
      (load file))))

(defun save-settings ()
  "Saves settings."
  (macrolet ((make-setting (setting)
               `(list 'setf ',setting ,setting)))
    (with-open-file (file *settings-location*
                          :direction :output
                          :if-exists :overwrite
                          :if-does-not-exist :create)
      (format file "~{~S~}" (list (make-setting *routing-table-location*)
                                  (make-setting *default-port*))))))

(define-condition kill-signal () ())

(defvar *listening-socket*)
;;; TODO: find_node each found node for nodes near the hash
(defun main-loop ()
  (handler-bind ((kill-signal (lambda (c) (declare (ignore c))
                                (return-from main-loop))))
    (with-listening-usocket socket
      (setf *listening-socket* socket)
      (unless *hashes*
        (error "No hashes set in *HASHES* variable."))
      (mapc (lambda (hash)
              ;; bootstrap the DHT with a known node
              (send-message :find_node "router.utorrent.com" 6881
                            :info-hash hash))
            *hashes*)
      (let ((start-time (get-universal-time)))
        (loop (multiple-value-bind (buffer size host port)
                  (receive-data)
                (let* ((packet (subseq buffer 0 size))
                       (dict (bencode:decode packet)))
                  (alexandria:switch ((gethash "y" dict) :test #'string=)
                    ("q" (parse-query dict host port))
                    ("r" (parse-response dict host port))
                    ("e" ;; TODO handle errors
                     ))))
              ;; TODO: routing table upkeep
              (when (= 0 (mod (minutes-since start-time) 10))
                (iterate-table (lambda (bucket)
                                 (purge-bad-nodes bucket)
                                 (handle-questionable-nodes bucket)
                                 (ping-old-nodes bucket)))))))))

(defun dht (&rest hashes)
  "Initiates the distributed hash table."
  (load-settings)
  (load-table)
  (when hashes
    (mapc (lambda (hash) (push hash *hashes*))
          hashes))
  (unwind-protect
       (main-loop)
    (progn (save-settings)
           (save-table))))
