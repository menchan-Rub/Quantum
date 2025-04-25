# src/crystal/quantum_core/security_context.cr
require "../utils/logger"
require "./network/response"
require "./events/dispatcher"
require "uri"
require "openssl"

module QuantumCore
  # ページのセキュリティコンテキストを管理するクラス
  # TLS状態、証明書情報、混合コンテンツ状態などを追跡する
  class SecurityContext
    # セキュリティレベル
    enum Level
      UNKNOWN   # 不明または非HTTP(S)
      SECURE    # 安全 (HTTPS、有効な証明書)
      MIXED     # 混合コンテンツ (HTTPSページ上のHTTPリソース)
      INSECURE  # 安全でない (HTTP)
      DANGEROUS # 危険 (証明書エラー、不正なサイト等)
    end

    # 証明書検証エラーの種類
    enum CertificateError
      NONE                    # エラーなし
      EXPIRED                 # 有効期限切れ
      NOT_YET_VALID           # まだ有効期間に入っていない
      REVOKED                 # 失効している
      UNTRUSTED_ROOT          # 信頼されていないルート証明書
      HOSTNAME_MISMATCH       # ホスト名不一致
      SELF_SIGNED             # 自己署名証明書
      WEAK_SIGNATURE_ALGORITHM # 弱い署名アルゴリズム
      UNKNOWN                 # その他のエラー
    end

    getter page_id : String
    getter current_level : Level
    getter certificate_info : Hash(String, String)?
    getter tls_version : String?
    getter cipher_suite : String?
    getter certificate_error : CertificateError
    getter mixed_content_resources : Array(String)
    getter hsts_enabled : Bool
    getter hpkp_enabled : Bool
    getter csp_enabled : Bool
    getter csp_report_only : Bool
    getter csp_violations : Array(String)
    
    @mixed_content_detected : Bool
    @event_dispatcher : Events::Dispatcher

    def initialize(@page_id : String, @event_dispatcher : Events::Dispatcher)
      @current_level = Level::UNKNOWN
      @certificate_info = nil
      @tls_version = nil
      @cipher_suite = nil
      @mixed_content_detected = false
      @certificate_error = CertificateError::NONE
      @mixed_content_resources = [] of String
      @hsts_enabled = false
      @hpkp_enabled = false
      @csp_enabled = false
      @csp_report_only = false
      @csp_violations = [] of String
      Log.debug "セキュリティコンテキストを作成しました（ページID: #{@page_id}）"
    end

    # ネットワーク応答に基づいてセキュリティ状態を更新する
    # @param response [QuantumNetwork::Response] メインリソースの応答
    def update_from_response(response : QuantumNetwork::Response)
      begin
        uri = URI.parse(response.url)
        
        # セキュリティヘッダーの解析
        parse_security_headers(response.headers)
        
        if uri.scheme == "https"
          if response.tls_certificate_valid?
            @current_level = @mixed_content_detected ? Level::MIXED : Level::SECURE
            @certificate_info = extract_certificate_info(response.tls_certificate)
            @tls_version = response.tls_version
            @cipher_suite = response.tls_cipher_suite
            @certificate_error = CertificateError::NONE
            Log.debug "セキュリティレベルを更新しました（ページID: #{@page_id}, レベル: #{@current_level}, TLS: #{@tls_version}）"
          else
            @current_level = Level::DANGEROUS
            @certificate_info = extract_certificate_info(response.tls_certificate)
            @certificate_error = determine_certificate_error(response.tls_certificate_error)
            Log.warn "証明書エラーのため危険なセキュリティレベルに設定しました（ページID: #{@page_id}, エラー: #{@certificate_error}）"
          end
        elsif uri.scheme == "http"
          @current_level = Level::INSECURE
          clear_tls_info
          Log.debug "セキュリティレベルを「安全でない」に更新しました（ページID: #{@page_id}）"
        else
          @current_level = Level::UNKNOWN # file://, about: など
          clear_tls_info
        end
      rescue ex
        Log.error "ページ #{@page_id} のセキュリティコンテキスト更新に失敗しました", exception: ex
        @current_level = Level::UNKNOWN
        clear_tls_info
      end
      
      # セキュリティ状態変更イベントを発行
      emit_security_state_changed_event
    end

    # サブリソース読み込み時に混合コンテンツを検出した場合に呼び出す
    # @param resource_url [String] 読み込まれたサブリソースのURL
    def report_mixed_content(resource_url : String)
      return unless @current_level == Level::SECURE || @current_level == Level::MIXED

      begin
        resource_uri = URI.parse(resource_url)
        if resource_uri.scheme == "http"
          @mixed_content_resources << resource_url unless @mixed_content_resources.includes?(resource_url)
          
          unless @mixed_content_detected
            @mixed_content_detected = true
            @current_level = Level::MIXED
            Log.warn "混合コンテンツを検出しました（ページID: #{@page_id}, リソース: #{resource_url}）"
            
            # セキュリティ状態変更イベントを発行
            emit_security_state_changed_event
          end
        end
      rescue ex
        Log.warn "混合コンテンツチェック用のリソースURL解析に失敗しました: #{resource_url}", exception: ex
      end
    end

    # CSPポリシー違反を報告する
    def report_csp_violation(directive : String, blocked_uri : String, document_uri : String)
      violation = "CSP違反: #{directive} (ブロックされたURI: #{blocked_uri}, ドキュメントURI: #{document_uri})"
      @csp_violations << violation
      Log.warn violation
    end

    # 状態をリセットする (ページクリーンアップ時など)
    def reset
      @current_level = Level::UNKNOWN
      clear_tls_info
      @mixed_content_detected = false
      @mixed_content_resources.clear
      @certificate_error = CertificateError::NONE
      @hsts_enabled = false
      @hpkp_enabled = false
      @csp_enabled = false
      @csp_report_only = false
      @csp_violations.clear
    end

    # セキュリティ情報の概要を取得する
    def summary : String
      case @current_level
      when Level::SECURE
        "安全な接続（HTTPS）"
      when Level::MIXED
        "安全な接続（HTTPS）- 混合コンテンツあり"
      when Level::INSECURE
        "安全でない接続（HTTP）"
      when Level::DANGEROUS
        "危険な接続 - #{certificate_error_description}"
      else
        "不明な接続状態"
      end
    end

    # 証明書エラーの説明を取得
    def certificate_error_description : String
      case @certificate_error
      when CertificateError::EXPIRED
        "証明書の有効期限が切れています"
      when CertificateError::NOT_YET_VALID
        "証明書はまだ有効期間に入っていません"
      when CertificateError::REVOKED
        "証明書は失効しています"
      when CertificateError::UNTRUSTED_ROOT
        "信頼されていないルート証明書です"
      when CertificateError::HOSTNAME_MISMATCH
        "証明書のホスト名が一致しません"
      when CertificateError::SELF_SIGNED
        "自己署名証明書です"
      when CertificateError::WEAK_SIGNATURE_ALGORITHM
        "証明書は弱い署名アルゴリズムを使用しています"
      when CertificateError::UNKNOWN
        "不明な証明書エラー"
      else
        ""
      end
    end

    private def clear_tls_info
      @certificate_info = nil
      @tls_version = nil
      @cipher_suite = nil
    end

    private def extract_certificate_info(certificate : OpenSSL::X509::Certificate?) : Hash(String, String)?
      return nil unless certificate

      {
        "発行者" => certificate.issuer.to_s,
        "対象者" => certificate.subject.to_s,
        "シリアル番号" => certificate.serial.to_s(16),
        "有効期間開始" => certificate.not_before.to_s,
        "有効期間終了" => certificate.not_after.to_s,
        "フィンガープリント" => calculate_fingerprint(certificate),
        "公開鍵アルゴリズム" => certificate.public_key.algorithm_name,
        "署名アルゴリズム" => certificate.signature_algorithm
      }
    end

    private def calculate_fingerprint(certificate : OpenSSL::X509::Certificate) : String
      OpenSSL::Digest.new("SHA256").update(certificate.to_der).final.hexstring
    end

    private def determine_certificate_error(error_code : String?) : CertificateError
      return CertificateError::NONE unless error_code

      case error_code
      when "CERT_EXPIRED"
        CertificateError::EXPIRED
      when "CERT_NOT_YET_VALID"
        CertificateError::NOT_YET_VALID
      when "CERT_REVOKED"
        CertificateError::REVOKED
      when "CERT_UNTRUSTED_ROOT"
        CertificateError::UNTRUSTED_ROOT
      when "CERT_HOSTNAME_MISMATCH"
        CertificateError::HOSTNAME_MISMATCH
      when "CERT_SELF_SIGNED"
        CertificateError::SELF_SIGNED
      when "CERT_WEAK_SIGNATURE_ALGORITHM"
        CertificateError::WEAK_SIGNATURE_ALGORITHM
      else
        CertificateError::UNKNOWN
      end
    end

    private def parse_security_headers(headers : Hash(String, String))
      # HSTS (HTTP Strict Transport Security)
      if headers.has_key?("Strict-Transport-Security")
        @hsts_enabled = true
        # HSTSの詳細解析はここに実装可能
      end

      # HPKP (HTTP Public Key Pinning)
      if headers.has_key?("Public-Key-Pins") || headers.has_key?("Public-Key-Pins-Report-Only")
        @hpkp_enabled = true
        # HPKPの詳細解析はここに実装可能
      end

      # CSP (Content Security Policy)
      if headers.has_key?("Content-Security-Policy")
        @csp_enabled = true
        # CSPの詳細解析はここに実装可能
      elsif headers.has_key?("Content-Security-Policy-Report-Only")
        @csp_enabled = true
        @csp_report_only = true
        # CSP Report Onlyの詳細解析はここに実装可能
      end
    end

    private def emit_security_state_changed_event
      @event_dispatcher.dispatch("security_state_changed", {
        "page_id" => @page_id,
        "security_level" => @current_level.to_s,
        "tls_version" => @tls_version,
        "has_certificate_error" => (@certificate_error != CertificateError::NONE),
        "certificate_error" => @certificate_error.to_s,
        "mixed_content" => @mixed_content_detected
      })
    end
  end
end
