class Spree::SofortController < ApplicationController

  skip_before_filter :verify_authenticity_token, :only => :status

  def success
    sofort_payment = Spree::Payment.find_by_sofort_hash(params[:sofort_hash])
    if params.blank? or params[:sofort_hash].blank? or sofort_payment.blank?
      flash[:error] = I18n.t("sofort.payment_not_found")
      redirect_to checkout_state_path(:payment), :status => 302
      return
    end

    order = sofort_payment.order
    if order.blank?
      flash[:error] = I18n.t("sofort.order_not_found")
      redirect_to checkout_state_path(:payment), :status => 302
      return
    end

    order.next unless order.complete?
    if order.complete?
      flash.notice = Spree.t(:order_processed_successfully)
      flash[:order_completed] = true
      session[:order_id] = nil
      success_redirect(order)
    else
      redirect_to checkout_state_path(order.state)
    end
  end

  def cancel
    flash[:error] = I18n.t("sofort.canceled")
    redirect_to checkout_state_path(:payment), :status => 302
  end

  def status
    Spree::SofortService.instance.eval_transaction_status_change(params)

    render :nothing => true
  end

  private

  def success_redirect order
    redirect_to order_path(order.number), :status => 302
  end

end
