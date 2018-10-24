# frozen_string_literal: true

require 'sinatra'
require 'endpoint_base'

require_relative './vend/client'
require_relative './vend/error_parser'
require_relative './vend/order_builder'
require_relative './vend/consignment_builder'
require_relative './vend/customer_builder'
require_relative './vend/product_builder'
require_relative './vend/purchase_order_builder'
require_relative './vend/supplier_builder'
require_relative './get_objects_endpoint'

class VendEndpointError < StandardError; end

class VendEndpoint < EndpointBase::Sinatra::Base
  VESRION = '0.0.1'
  extend GetObjectsEndpoint

  set :logging, true

  attr_reader :payload

  def add_object(key, value)
    case value
    when Hash
      super key, value.merge(channel: 'Vend')
    else
      super
    end
  end

  get_endpoint :outlet
  get_endpoint :customer
  get_endpoint :product
  get_endpoint :purchase_order
  get_endpoint :vendor
  get_endpoint :register_sale
  get_endpoint :tax_rate

  post '/get_purchase_order' do
    begin
      code = 200
      consignment_id = payload['purchase_order']['id']
      name = payload['purchase_order']['name']
      response = client.get_purchase_order(consignment_id: consignment_id,
                                           name: name)
      if response.present?
        set_summary "Retrieved Consignment #{response.dig 'data', 'id'} purchase order from Vend"
        add_object :purchase_order, response['data']
      end
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/get_transfer_order' do
    begin
      code = 200
      consignment_id = payload['transfer_order']['id']
      name = payload['transfer_order']['name']
      response = client.get_purchase_order(consignment_id: consignment_id,
                                           name: name)
      if response.present?
        set_summary "Retrieved Consignment #{response.dig 'data', 'id'} transfer order from Vend"
        add_object :transfer_order, response['data']
      end
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/get_inventory_counts' do
    begin
      code = 200
      response = client.get_purchase_order(consignment_id: payload['inventory_adjustment']['id'])

      set_summary "Retrieved inventory count #{response.dig 'data', 'id'}  from Vend"
      add_object :inventory_adjustment, response['data']
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/add_purchase_order' do
    begin
      payload = @payload[:purchase_order]
      response = client.send_purchase_order(payload)
      code = 200
      if payload['status'] == 'CANCELLED'
      # ignore cancelled orders
      elsif payload['txn_type'] == 'RECEIPT'
        # update receipts only
        Vend::PurchaseOrderBuilder.new(response.to_h, client).to_hash
        else
          add_object 'purchase_order', Vend::PurchaseOrderBuilder.new(response.to_h, client).to_hash
          set_summary "Added purchase order #{response['name']} to Vend"
        end
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/add_transfer_order' do
    begin
      payload = @payload[:transfer_order]
      response = client.send_purchase_order(payload)
      code = 200
      if payload['status'] == 'CANCELLED'
      # ignore cancelled orders
        cancel_transfer_xref(payload['transfer_name'])
      elsif payload['txn_type'] == 'RECEIPT'
        # update receipts only
        Vend::PurchaseOrderBuilder.new(response.to_h, client).to_hash
        else
          add_object 'transfer_order', Vend::PurchaseOrderBuilder.new(response.to_h, client).to_hash
          set_summary "Added transfer order #{response['name']} to Vend"
        end
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/add_vendor' do
    begin
      response = client.send_supplier(@payload[:vendor])
      add_object 'vendor', response.as_json
      set_summary "Added vendor #{response['name']} to Vend"
      code = 200
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/update_inventory' do
    begin
        if @payload[:inventory].present?
          response = client.update_inventory(@payload[:inventory])
          set_summary "update inventory #{response['sku']} to Vend"
          code = 200
        else
          code = 200
          set_summary "update inventory skip to Vend"
        end
      rescue VendEndpointError => e
        code = 500
        set_summary "Validation error has ocurred: #{e.message}"
      rescue => e
        code = 500
        error_notification(e)
      end


      process_result code
  end

  post '/add_order' do
    begin
      @payload[:order][:register] = @config['vend_register']
      response                    = client.send_order(@payload[:order])
      code                        = 200
      add_object 'order', response.as_json['register_sale']
      set_summary "The order #{@payload[:order][:id]} was sent to Vend POS."
    rescue VendEndpointError => e
      code = 500
      set_summary "Validation error has ocurred: #{e.message}"
    rescue => e
      code = 500
      error_notification(e)
    end

    process_result code
  end

  post '/add_product' do
       begin
        if Array(@payload[:product]['variants']).any?
          @payload[:product]['variants'].each do |variant|
              product = @payload[:product].dup
              variant['handle']=variant['old_handle']||payload['product']['handle']
              variant['description']=payload['product']['description']
              variant['name']=payload['product']['name']
              variant['option_value']=variant['option_value']||variant['old_option_value']||'def'
              variant['option_name']=variant['option_name']||variant['old_option_name']||'color'
              if variant['id'].nil?
                 verify_sku(variant)
              else
                  # if sku has been deleted if so empty out id so vend will recreate
                  resp=client.find_product_by_id(variant['id'])
                  if !resp.present? || !resp['deleted_at'].nil?
                    variant['id']=nil
                    verify_sku(variant)
                  else
                    @sku_changed=variant['changed']
                  end
              end
          if  @sku_changed
              product.merge!(variant)
              response = client.send_product(product)
              ExternalReference.record :product, variant['sku'] , { vend: response['product'] },vend_id: response['product']['id']

              if response['product']['id'].present? &&
                !response['images'].present? &&
                variant['image'].present?
                uploadresponse=client.upload_product_image(response['product']['id'],variant['image'])
              end
          end
        end
          end

        code = 200
       set_summary "The product #{@payload[:product][:name]} #{@payload[:product][:name]} was sent to Vend POS."

       rescue VendEndpointError => e
         code = 500
         set_summary "Validation error has ocurred: #{e.message}"
       rescue => e
         code = 500
         error_notification(e)
       end

      process_result code
     end


  def verify_sku(variant)
    resp=client.get_sku_product(variant['sku'])&.detect {|f| f["sku"] = variant['sku'] }
    if resp.present?
      @sku_changed = ( variant['changed'] == true ||
                    variant['sku'] != resp['sku'] ||
                    payload['product']['name'] != resp['base_name'] ||
                    variant['id'] != resp['id'] ||
                    variant['price'].to_f != resp['price'].to_f ||
                    variant['cost_price'].to_f != resp['supply_price'].to_f) ||
                  ( variant['image'].present? && !resp['images'].present? )

      #grab vend data if avaliable
      variant['id'] = resp['id']
      variant['handle'] = resp['handle']
      else @sku_changed = true
    end

  end

  def error_notification(error)
    log_exception(error)
    Honeybadger.notify error
    set_summary "A Vend POS Endpoint error has ocurred: #{error.message}"
  end

  def client
    @client ||= Vend::Client.new(settings.site_id, settings.token)
  end

  def cancel_transfer_xref(name)
    if reference = ExternalReference.transfer_orders
                                    .find_by(identifier: name + 'SENT')
      reference.object['vend']['status'] = 'CANCELLED'
      reference.save!
    end

    if reference = ExternalReference.transfer_orders
                                    .find_by(identifier: name + 'RECEIVED')
      reference.object['vend']['status'] = 'CANCELLED'
      reference.save!
    end
  end

end
