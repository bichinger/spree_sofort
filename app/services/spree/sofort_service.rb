require 'httparty'

module Spree
  class SofortService

    include Singleton

    # make the initialization request
    # https://www.sofort.com/integrationCenter-ger-DE/content/view/full/2513#h6-1
    # https://www.sofort.com/integrationCenter-ger-DE/content/view/full/2513#h6-2
    def initial_request order, ref_number=nil
      init_data(order)
      ref_number = @order.sofort_ref_number if ref_number.blank?
      @order.update_attribute(:sofort_hash, build_exit_param)
      raw_response = HTTParty.post(@sofort.preferred_server_url,
                                  :headers => header,
                                  :body => initial_request_body(ref_number))

      response = parse_initial_response(raw_response)
      @order.update_attribute(:sofort_transaction, response[:transaction])
      return response
    end

    # evaluate transaction status change
    # https://www.sofort.com/integrationCenter-ger-DE/content/view/full/2513#h6-3
    # https://www.sofort.com/integrationCenter-ger-DE/content/view/full/2513#h6-4
    # https://www.sofort.com/integrationCenter-ger-DE/content/view/full/2513#h6-5
    def eval_transaction_status_change params
      return if params.blank? or params[:status_notification].blank? or params[:status_notification][:transaction].blank?
      init_data(Spree::Order.find_by_sofort_transaction(params[:status_notification][:transaction]))

      raw_response = HTTParty.post(@sofort.preferred_server_url,
                                  :headers => header,
                                  :body => transaction_request_body)

      new_entry = I18n.t("sofort.transaction_status_default")
      if raw_response.parsed_response["transactions"].present? and
         raw_response.parsed_response["transactions"]["transaction_details"].present?

        td = raw_response.parsed_response["transactions"]["transaction_details"]
        alter_payment_status(td)
        new_entry = "#{td["time"]}: #{td["status"]} / #{td["status_reason"]} (#{td["amount"]})"
      end
      old_entries = @order.sofort_log || ""
      @order.update_attribute(:sofort_log, old_entries += "#{new_entry}\n")
    end


    private

    def alter_payment_status transaction_details
      if transaction_details["status"].present?
        if transaction_details["status"].eql? "loss"
          @order.last_payment.void
        elsif transaction_details["status"].eql? "pending"
          @order.last_payment.complete
        elsif transaction_details["status"].eql? "refunded"
          @order.last_payment.void
        else # received
          @order.last_payment.complete
        end
      end
    end

    def init_data(order, cancel_url = "/checkout/payment")
      raise I18n.t("sofort.no_order_given") if order.blank?
      @order = order
      @cancel_url = cancel_url

      raise I18n.t("sofort.order_has_no_payment_method") if @order.last_payment_method.blank?
      raise I18n.t("sofort.orders_payment_method_is_not_sofort") unless @order.last_payment_method.kind_of? Spree::PaymentMethod::Sofort
      @sofort = @order.last_payment_method

      raise I18n.t("sofort.config_key_is_blank") if @sofort.preferred_config_key.blank?
      config_key_parts = @sofort.preferred_config_key.split(":")
      raise I18n.t("sofort.config_key_is_invalid") if config_key_parts.length < 3

      @user_id = config_key_parts[0]
      @project_id = config_key_parts[1]
      @api_key = config_key_parts[2]
      @http_auth_key = "#{@user_id}:#{@api_key}"
    end

    def header
      return {
        "Authorization" => "Basic #{Base64.encode64(@http_auth_key)}",
        "Content-Type" => "application/xml; charset=UTF-8",
        "Accept" => "application/xml; charset=UTF-8"
      }
    end

    def initial_request_body ref_number
      base_url = "http://#{Spree::Config.site_url}"
      notification_url = (Spree::Config.site_url.blank? or Spree::Config.site_url.start_with?("localhost")) ? "" : "#{base_url}/sofort/status"
      body_hash = {
        :su => {},
        :amount => @order.total,
        :currency_code => Spree::Config.currency,
        :reasons => {:reason => ref_number},
        :success_url => "#{base_url}/sofort/success?oid=#{@order.sofort_hash}",
        :success_link_redirect => "1",
        :abort_url => "#{base_url}/sofort/cancel",
        # no url with port as notification url allowed
        :notification_urls => {:notification_url => notification_url},
        :project_id => @project_id
      }
      body_hash.to_xml(:dasherize => false, :root => 'multipay',
                       :root_attrs => {:version => '1.0'})
    end

    def transaction_request_body
      body_hash = {
        :transaction => @order.sofort_transaction
      }
      body_hash.to_xml(:dasherize => false, :root => 'transaction_request',
                       :root_attrs => {:version => '2'})
    end

    def parse_initial_response raw_response
      response = {}
      if raw_response.parsed_response.blank?
        response[:redirect_url] = @cancel_url
        response[:transaction] = ""
        response[:error] = I18n.t("sofort.unauthorized")
      elsif raw_response.parsed_response["errors"].present?
        response[:redirect_url] = @cancel_url
        response[:transaction] = ""
        all_errors = raw_response.parsed_response["errors"]["error"]
        if all_errors.kind_of?(Array)
          response[:error] = I18n.t("sofort.error_from_sofort")+": "+(all_errors.map { |e| "#{e['field']}: #{e['message']}" }.join(", "))
        else
          response[:error] = I18n.t("sofort.error_from_sofort")+": "+all_errors["field"]+":"+all_errors["message"]
        end
      else
        response[:redirect_url] = raw_response.parsed_response["new_transaction"]["payment_url"]
        response[:transaction] = raw_response.parsed_response["new_transaction"]["transaction"]
      end
      return response
    end

    def build_exit_param
      Digest::SHA2.hexdigest(@order.number+@sofort.preferred_config_key)
    end

  end
end
