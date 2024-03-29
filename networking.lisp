;;;; Code related to communicating
;;;; with nodes over the network

(in-package #:dhticl)

(defvar *listening-socket*)

(defvar *results-list* (list)
  "A list containing nodes received from find_node queries.")

(defvar *previous-best-results* (list))

(defvar *best-results* (list)
  "A list containing the k best results from a find_node lookup.")

(defvar *active-lookups* (make-hash-table :test #'equal)
  "A hash table containing currently active lookups.")

(defconstant +alpha+ 3
  "The number of simultaneous lookups to perform.")

(defun ping-old-nodes (bucket)
  "Pings the nodes in a bucket from oldest to newest."
  (sort-bucket-by-age bucket)
  (iterate-bucket bucket
                  (lambda (node)
                    (send-message :ping (node-ip node) (node-port node)
                                  (generate-transaction-id))))
  (update-bucket bucket)
  (sort-bucket-by-distance bucket))

(defun purge-bad-nodes (bucket)
  "Removes all nodes of bad health from BUCKET."
  (map-into (bucket-nodes bucket)
            (lambda (node)
              (unless (eql :bad (node-health node))
                node))
            (bucket-nodes bucket))
  (update-bucket bucket)
  (sort-bucket-by-distance bucket))
;;; TODO: can this be done better?
(defun handle-questionable-node (node)
  "Checks the health of NODE."
  (send-message :ping (node-ip node) (node-port node)
                (generate-transaction-id)))

(defun handle-questionable-nodes (bucket)
  "Handles all nodes in BUCKET that are of questionable health."
  (iterate-bucket bucket
                  (lambda (node)
                    (when (eql :questionable (node-health node))
                      (handle-questionable-node node))))
  (update-bucket bucket))

(defun ping-oldest-node (bucket)
  "Pings the oldest node in BUCKET."
  (sort-bucket-by-age bucket)
  (let ((node (svref bucket 0)))
    (send-message :ping (node-ip node) (node-port node)
                  (generate-transaction-id)))
  (sort-bucket-by-distance bucket))

(defun lookup (node)
  "Begins a lookup of NODE."
  (let ((transaction-id (generate-transaction-id)))
    (send-message :ping (node-ip node) (node-port node) transaction-id)
    (setf (gethash transaction-id *active-lookups*) node)))

(defun ping-results! ()
  "Begins looking up nodes in the intermediary results list."
  (loop for node in *results-list*
        while (< (hash-table-count *active-lookups*) +alpha+)
        do (lookup node)
           (pop *results-list*)))

(defun sort-best-results! ()
  (setf *best-results*
        (sort *best-results* #'< :key #'node-distance)))

(defun parse-query (dict ip port)
  "Parses a Bencoded query dictionary."
  (let* ((now (get-universal-time))
         (arguments (gethash "a" dict))
         (id (gethash "id" arguments))
         (info-hash (gethash "info_hash" arguments))
         (token (gethash "token" arguments))
         (distance (calculate-distance (convert-id-to-int +my-id+)
                                       (convert-id-to-int id)))
         (node (find-node-in-table id)))
    (if node
        (setf (node-last-activity node) now
              (node-health node) :good)
        (progn (setf node (create-node :id id :ip ip :port port
                                       :distance distance
                                       :last-activity now
                                       :health :good))
               (push node *node-list*)
               (add-to-bucket node)
               (setf (gethash (gethash "t" dict) *transactions*) t)))
    (alexandria:switch ((gethash "q" dict) :test #'string=)
      ("ping" (send-response :ping node dict))
      ("find_node" (send-response :find_node node dict))
      ("get_peers" (send-response :get_peers node dict))
      ("announce_peer" (cond ((member token (recall-token info-hash)
                                      :test #'equalp)
                              (push node (gethash info-hash *peer-list*))
                              (send-response :announce_peer node dict
                                             :source-port port))
                             (t (send-response :dht_error node dict
                                               :error-type :protocol)))))))

(defun parse-response (dict ip port)
  "Parses a Bencoded response dictionary."
  (flet ((parse-nodes (str)
           (let (nodes)
             (handler-case
                 (do ((i 0 (+ i 26))) ; operate on compact node info substrings
                     ((= i (length str)) nodes)
                   (multiple-value-bind (parsed-ip parsed-port)
                       (parse-node-ip (subseq str (+ i 20) (+ i 26)))
                     ;; (list node-id node-ip node-port)
                     (push (list (subseq str i (+ i 20)) parsed-ip parsed-port)
                           nodes)))
               ;; TODO: error handling for out-of-bounds
               ;; (node's health is bad--malformed response sent)
               (error () (return-from parse-nodes nodes)))))
         (parse-peers (str)
           (let (peers)
            (handler-case
                (do ((i 0 (+ i 6))) ; operate on compact peer info substrings
                    ((= i (length str)) peers)
                  (multiple-value-bind (parsed-ip parsed-port)
                      (parse-node-ip (subseq str i (+ i 6)))
                    (push (cons parsed-ip parsed-port) peers)))
              ;; TODO: error handling for out-of-bounds
              ;; (node's health is bad--malformed response sent)
              (error () (return-from parse-peers peers))))))
    (let* ((now (get-universal-time))
           (transaction-id (gethash "t" dict))
           (arguments (gethash "a" dict))
           (id (gethash "id" arguments))
           (info-hash (gethash "info_hash" arguments))
           ;; TOKEN comes from a get_peers response, needed for announce_peer
           (token (gethash "token" arguments))
           ;; NODES comes from a find_node or get_peers response
           (nodes (gethash "nodes" arguments))
           ;; VALUES is a list of strings which are compact peer info
           ;; Comes from a get_peers response
           (values (gethash "values" arguments))
           (implied-port (gethash "implied_port" arguments))
           (peer-port (gethash "port" arguments))
           (node (car (member id *node-list* :key #'node-id :test #'string=))))
      ;; handle bookkeeping of the node
      (if node
          (progn (setf (node-last-activity node) (get-universal-time)
                       (node-health node) :good)
                 (cond ((and implied-port (= implied-port 1))
                        (setf (node-port node) port))
                       (peer-port (setf (node-port node) peer-port))))
          (progn (setf node (create-node :id id :ip ip :port port
                                         :distance
                                         (calculate-distance
                                          (convert-id-to-int id)
                                          (convert-id-to-int +my-id+))
                                         :last-activity (get-universal-time)
                                         :health :good))
                 (push node *node-list*)
                 (add-to-bucket node)))
      ;; bad transaction ID
      (unless (gethash transaction-id *transactions*)
        (send-response :dht_error node dict :error-type :protocol)
        (setf (node-health node) :bad))
      ;; find_node lookup response
      (when (gethash transaction-id *active-lookups*)
        (if (= (length *best-results*) +k+)
            ;; we only want the k closest nodes
            (unless (< (node-distance (last *best-results*))
                       (node-distance node))
              (setf *best-results* (cons node (butlast *best-results*)))
              (sort-best-results!))
            (progn (push node *best-results*)
                   (sort-best-results!)))
        (remhash transaction-id *active-lookups*)
        (cond (*results-list* ; if *RESULTS-LIST* isn't empty
               (lookup (first *results-list*))
               (pop *results-list*))
              ((equalp *best-results* *previous-best-results*)) ; stop recursion
              (t
               (setf *previous-best-results* *best-results*)
               (mapc (lambda (node)
                       (send-message :find_node
                                     (node-ip node)
                                     (node-port node)
                                     (generate-transaction-id)))
                     *best-results*))))
      (when nodes
        (let ((node-list (parse-nodes nodes)))
          (loop for (node-id node-ip node-port) in node-list
                for node = (create-node
                            :id node-id :ip node-ip :port node-port
                            :distance (calculate-distance
                                       (convert-id-to-int +my-id+)
                                       (convert-id-to-int node-id)))
                do (push node *results-list*)))
        (ping-results!))
      (when values
        (let ((peer-list (parse-peers values)))
          (loop for (peer-ip . peer-port) in peer-list
                do (send-message :ping peer-ip peer-port))))
      ;; store received token
      (when token
        (setf (gethash token *token-births*) now

              (gethash (gethash transaction-id *transactions*) *token-hashes*)
              token

              (gethash token *token-nodes*) node)))))

(defun parse-message ()
  "Parses a KRPC message."
  (multiple-value-bind (data size host port)
      (receive-data)
    (let* ((packet (subseq data 0 size))
           (dict (bencode:decode packet)))
      (alexandria:eswitch ((gethash "y" dict) :test #'string=)
        ("q" (parse-query dict host port))
        ("r" (parse-response dict host port))
        ("e" ;; TODO: handle errors
         )))))
