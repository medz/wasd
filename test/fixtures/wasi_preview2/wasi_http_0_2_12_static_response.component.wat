(component
  (type $types_ty (instance
    (type $opt_string (option string))
    (type $opt_u16 (option u16))
    (type $dns_error_payload
      (record
        (field "rcode" $opt_string)
        (field "info-code" $opt_u16)))
    (export "DNS-error-payload"
      (type $dns_error_payload_export (eq $dns_error_payload)))
    (type $opt_u8 (option u8))
    (type $tls_alert_payload
      (record
        (field "alert-id" $opt_u8)
        (field "alert-message" $opt_string)))
    (export "TLS-alert-received-payload"
      (type $tls_alert_payload_export (eq $tls_alert_payload)))
    (type $opt_u32 (option u32))
    (type $field_size_payload
      (record
        (field "field-name" $opt_string)
        (field "field-size" $opt_u32)))
    (export "field-size-payload"
      (type $field_size_payload_export (eq $field_size_payload)))
    (type $opt_u64 (option u64))
    (type $opt_field_size_payload (option $field_size_payload_export))
    (type $error_code
      (variant
        (case "DNS-timeout")
        (case "DNS-error" $dns_error_payload_export)
        (case "destination-not-found")
        (case "destination-unavailable")
        (case "destination-IP-prohibited")
        (case "destination-IP-unroutable")
        (case "connection-refused")
        (case "connection-terminated")
        (case "connection-timeout")
        (case "connection-read-timeout")
        (case "connection-write-timeout")
        (case "connection-limit-reached")
        (case "TLS-protocol-error")
        (case "TLS-certificate-error")
        (case "TLS-alert-received" $tls_alert_payload_export)
        (case "HTTP-request-denied")
        (case "HTTP-request-length-required")
        (case "HTTP-request-body-size" $opt_u64)
        (case "HTTP-request-method-invalid")
        (case "HTTP-request-URI-invalid")
        (case "HTTP-request-URI-too-long")
        (case "HTTP-request-header-section-size" $opt_u32)
        (case "HTTP-request-header-size" $opt_field_size_payload)
        (case "HTTP-request-trailer-section-size" $opt_u32)
        (case "HTTP-request-trailer-size" $field_size_payload_export)
        (case "HTTP-response-incomplete")
        (case "HTTP-response-header-section-size" $opt_u32)
        (case "HTTP-response-header-size" $field_size_payload_export)
        (case "HTTP-response-body-size" $opt_u64)
        (case "HTTP-response-trailer-section-size" $opt_u32)
        (case "HTTP-response-trailer-size" $field_size_payload_export)
        (case "HTTP-response-transfer-coding" $opt_string)
        (case "HTTP-response-content-coding" $opt_string)
        (case "HTTP-response-timeout")
        (case "HTTP-upgrade-failed")
        (case "HTTP-protocol-error")
        (case "loop-detected")
        (case "configuration-error")
        (case "internal-error" $opt_string)))
    (export "error-code" (type $error_code_export (eq $error_code)))

    (export "fields" (type $fields (sub resource)))
    (export "incoming-request" (type $incoming_request (sub resource)))
    (export "response-outparam" (type $response_outparam (sub resource)))
    (export "outgoing-response" (type $outgoing_response (sub resource)))

    (type $new_fields_ty (func (result (own $fields))))
    (export "[constructor]fields" (func (type $new_fields_ty)))
    (type $new_response_ty (func
      (param "headers" (own $fields))
      (result (own $outgoing_response))))
    (export "[constructor]outgoing-response"
      (func (type $new_response_ty)))
    (type $set_response_ty (func
      (param "param" (own $response_outparam))
      (param "response"
        (result (own $outgoing_response) (error $error_code_export)))))
    (export "[static]response-outparam.set"
      (func (type $set_response_ty)))))

  (import "wasi:http/types@0.2.12"
    (instance $types (type $types_ty)))
  (alias export $types "fields" (type $fields))
  (alias export $types "incoming-request" (type $incoming_request))
  (alias export $types "response-outparam" (type $response_outparam))
  (alias export $types "outgoing-response" (type $outgoing_response))
  (alias export $types "[constructor]fields" (func $new_fields))
  (alias export $types "[constructor]outgoing-response" (func $new_response))
  (alias export $types "[static]response-outparam.set" (func $set_response))

  (core module $memory_module
    (memory (export "memory") 1))
  (core instance $memory_instance (instantiate $memory_module))
  (alias core export $memory_instance "memory" (core memory $memory))

  (core func $new_fields_core (canon lower (func $new_fields)))
  (core func $new_response_core (canon lower (func $new_response)))
  (core func $set_response_core
    (canon lower (func $set_response) (memory $memory)))
  (core instance $host_core
    (export "new-fields" (func $new_fields_core))
    (export "new-response" (func $new_response_core))
    (export "set-response" (func $set_response_core)))

  (core module $main
    (import "host" "new-fields" (func $new_fields (result i32)))
    (import "host" "new-response"
      (func $new_response (param i32) (result i32)))
    (import "host" "set-response"
      (func $set_response
        (param i32 i32 i32 i32 i64 i32 i32 i32 i32)))
    (func (export "handle") (param $request i32) (param $response_out i32)
      local.get $response_out
      i32.const 0
      call $new_fields
      call $new_response
      i32.const 0
      i64.const 0
      i32.const 0
      i32.const 0
      i32.const 0
      i32.const 0
      call $set_response))
  (core instance $main_instance
    (instantiate $main (with "host" (instance $host_core))))
  (alias core export $main_instance "handle" (core func $handle_core))

  (type $handle_ty (func
    (param "request" (own $incoming_request))
    (param "response-out" (own $response_outparam))))
  (func $handle (type $handle_ty)
    (canon lift (core func $handle_core)))
  (instance $incoming_handler
    (export "handle" (func $handle)))
  (export "wasi:http/incoming-handler@0.2.12"
    (instance $incoming_handler))
)
