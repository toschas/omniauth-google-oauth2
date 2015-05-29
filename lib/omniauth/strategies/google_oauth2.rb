require 'multi_json'
require 'jwt'
require 'omniauth/strategies/oauth2'

module OmniAuth
  module Strategies
    class GoogleOauth2 < OmniAuth::Strategies::OAuth2
      BASE_SCOPE_URL = "https://www.googleapis.com/auth/"
      BASE_SCOPES = %w[profile email openid]
      DEFAULT_SCOPE = "email,profile"

      option :name, 'google_oauth2'

      option :skip_friends, true

      option :authorize_options, [:access_type, :hd, :login_hint, :prompt, :request_visible_actions, :scope, :state, :redirect_uri, :include_granted_scopes, :openid_realm]

      option :client_options, {
        :site          => 'https://accounts.google.com',
        :authorize_url => '/o/oauth2/auth',
        :token_url     => '/o/oauth2/token'
      }

      def authorize_params
        super.tap do |params|
          options[:authorize_options].each do |k|
            params[k] = request.params[k.to_s] unless [nil, ''].include?(request.params[k.to_s])
          end

          raw_scope = params[:scope] || DEFAULT_SCOPE
          scope_list = raw_scope.split(" ").map {|item| item.split(",")}.flatten
          scope_list.map! { |s| s =~ /^https?:\/\// || BASE_SCOPES.include?(s) ? s : "#{BASE_SCOPE_URL}#{s}" }
          params[:scope] = scope_list.join(" ")
          params[:access_type] = 'offline' if params[:access_type].nil?
          params['openid.realm'] = params.delete(:openid_realm) unless params[:openid_realm].nil?

          session['omniauth.state'] = params[:state] if params['state']
        end
      end

      uid { raw_info['sub'] || verified_email }

      info do
        prune!({
          :name       => raw_info['name'],
          :email      => verified_email,
          :first_name => raw_info['given_name'],
          :last_name  => raw_info['family_name'],
          :image      => image_url,
          :urls => {
            'Google' => raw_info['profile']
          }
        })
      end

      extra do
        hash = {}
        hash[:id_token] = access_token['id_token']
        if !access_token['id_token'].nil?
          hash[:id_info] = JWT.decode(
            access_token['id_token'], nil, false, {
              :verify_iss => true,
              'iss' => 'accounts.google.com',
              :verify_aud => true,
              'aud' => options.client_id,
              :verify_sub => false,
              :verify_expiration => true,
              :verify_not_before => true,
              :verify_iat => true,
              :verify_jti => false
            }).first
        end
        hash[:raw_info] = raw_info unless skip_info?
        hash[:raw_friend_info] = raw_friend_info(raw_info['sub']) unless skip_info? || options[:skip_friends]
        prune! hash
      end

      def raw_info
        @raw_info ||= access_token.get('https://www.googleapis.com/plus/v1/people/me/openIdConnect').parsed
      end

      def raw_friend_info(id)
        @raw_friend_info ||= access_token.get("https://www.googleapis.com/plus/v1/people/#{id}/people/visible").parsed
      end

      def custom_build_access_token
        if request.xhr? && request.params['code']
          verifier = request.params['code']
          client.auth_code.get_token(verifier, { :redirect_uri => 'postmessage' }.merge(token_params.to_hash(:symbolize_keys => true)),
                                     deep_symbolize(options.auth_token_params || {}))
        elsif request.params['code']
          verifier = request.params['code']
          redirect_uri = 'postmessage'
          client.auth_code.get_token(verifier, { :redirect_uri => redirect_uri }.merge(token_params.to_hash(:symbolize_keys => true)),
                                     deep_symbolize(options.auth_token_params || {}))
        elsif verify_token(request.params['id_token'], request.params['access_token'])
          ::OAuth2::AccessToken.from_hash(client, request.params.dup)
        else
          orig_build_access_token
        end
      end
      alias_method :orig_build_access_token, :build_access_token
      alias_method :build_access_token, :custom_build_access_token

      private

      def prune!(hash)
        hash.delete_if do |_, v|
          prune!(v) if v.is_a?(Hash)
          v.nil? || (v.respond_to?(:empty?) && v.empty?)
        end
      end

      def verified_email
        raw_info['email_verified'] ? raw_info['email'] : nil
      end

      def image_url
        return nil unless raw_info['picture']

        u = URI.parse(raw_info['picture'].gsub('https:https', 'https'))
        path_index = u.path.to_s.index('/photo.jpg')

        if path_index && image_size_opts_passed?
          u.path.insert(path_index, image_params)
          u.path = u.path.gsub('//', '/')
        end

        u.to_s
      end

      def image_size_opts_passed?
        !!(options[:image_size] || options[:image_aspect_ratio])
      end

      def image_params
        image_params = []
        if options[:image_size].is_a?(Integer)
          image_params << "s#{options[:image_size]}"
        elsif options[:image_size].is_a?(Hash)
          image_params << "w#{options[:image_size][:width]}" if options[:image_size][:width]
          image_params << "h#{options[:image_size][:height]}" if options[:image_size][:height]
        end
        image_params << 'c' if options[:image_aspect_ratio] == 'square'

        '/' + image_params.join('-')
      end

      def verify_token(id_token, access_token)
        return false unless (id_token && access_token)

        raw_response = client.request(:get, 'https://www.googleapis.com/oauth2/v2/tokeninfo', :params => {
          :id_token => id_token,
          :access_token => access_token
        }).parsed
        raw_response['issued_to'] == options.client_id
      end
    end
  end
end
