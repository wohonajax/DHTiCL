;;;; Code related to communicating
;;;; with nodes over the network

(in-package #:dhticl)

(defun calculate-elapsed-inactivity (node)
  "Returns the time in minutes since NODE's last seen activity."
  (and (node-last-activity node) (minutes-since last-activity)))

(defun calculate-node-health (node)
  "Returns the node's health as a keyword, either :GOOD, :QUESTIONABLE,
or :BAD."
  (let ((time-inactive (calculate-elapsed-inactivity node)))
    (cond ((null time-inactive) :questionable)
          ((< time-inactive 15) :good)
          (t :bad))))

(defun ping-old-nodes (bucket)
  "Pings the nodes in a bucket from oldest to newest."
  (sort-bucket-by-age bucket)
  (iterate-bucket bucket
                  (lambda (node)
                    (send-message :ping (node-ip node) (node-port node))))
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
  (send-message :ping (node-ip node) (node-port node)))

(defun handle-questionable-nodes (bucket)
  "Handles all nodes in BUCKET that are of questionable health."
  (iterate-bucket bucket
                  (lambda (node)
                    (when (eql :questionable (node-health node))
                      (handle-questionable-node node))))
  (update-bucket bucket))

(defun parse-query (dict ip port)
  "Parses a Bencoded query dictionary."
  (let* ((now (get-universal-time))
         (arguments (gethash "a" dict))
         (id (gethash "id" arguments))
         (info-hash (gethash "info_hash" arguments))
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
      ("announce_peer" (push node (gethash info-hash *peer-list*))
                       (send-response :announce_peer node dict
                                      :source-port port)))))

(defun parse-response (dict ip port)
  "Parses a Bencoded response dictionary."
  (flet ((parse-nodes (str)
           (let (nodes)
             (handler-case
                 (do ((i 0 (* i 26))) ; operate on compact node info substrings
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
                (do ((i 0 (* i 6))) ; operate on compact peer info substrings
                    ((= i (length str)) peers)
                  (multiple-value-bind (parsed-ip parsed-port)
                      (parse-node-ip (subseq str i (+ i 6)))
                    (push (cons parsed-ip parsed-port) peers)))
              ;; TODO: error handling for out-of-bounds
              ;; (node's health is bad--malformed response sent)
              (error () (return-from parse-peers peers))))))
    (let* ((transaction-id (gethash "t" dict))
           (arguments (gethash "a" dict))
           (id (gethash "id" arguments))
           (info-hash (gethash "info_hash" arguments))
           ;; TOKEN comes from a get_peers response, needed for announce_peer
           (token (gethash "token" arguments))
           ;; NODES comes from a find_node or get_peers response
           (nodes (gethash "nodes" arguments))
           ;; VALUES is a list of strings which are compact node info
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
      (when nodes
        (let ((node-list (parse-nodes nodes)))
          (loop for (node-id node-ip node-port) in node-list
                for node = (create-node
                            :id node-id :ip node-ip :port node-port
                            :distance (calculate-distance
                                       (convert-id-to-int +my-id+)
                                       (convert-id-to-int node-id)))
                do (push node *node-list*)
                (add-to-bucket node)
                (send-message :ping node-ip node-port))))
      (when values
        (let ((peer-list (parse-peers values)))
          (loop for (peer-ip . peer-port) in peer-list
                do (send-message :ping peer-ip peer-port))))
      (when token
        (unless (and (valid-token-p token)
                     (consider-token token info-hash node))
          (send-response :dht_error node dict :error-type :protocol))))))
