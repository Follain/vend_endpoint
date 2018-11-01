# frozen_string_literal: true

require 'httmultiparty'
require 'peach'
require_relative './poll_client'
require 'open-uri'

module Vend
  class Client
    include ::HTTMultiParty
    extend  ::Vend::PollClient

    attr_reader :site_id, :headers, :multi_header

    def initialize(site_id, personal_token)
      @site_id = site_id
      @headers = {
        'Content-Type' => 'application/json',
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{personal_token}"
      }

      @multi_header = {
        'content-type' => 'multipart/form-data',
        'Accept' => 'application/json',
        'Authorization' => "Bearer #{personal_token}"
      }
      self.class.base_uri "https://#{site_id}.vendhq.com/api/"
    end

    poll :customers
    poll vendors: :suppliers
    poll :outlets
    poll purchase_orders: :consignments
    poll :products
    poll register_sales: :sales
    poll tax_rates: :taxes

    def send_order(payload)
      order_placed_hash = Vend::OrderBuilder.order_placed(self, payload)

      options = {
        headers: headers,
        body: order_placed_hash.to_json
      }

      response = self.class.post('/register_sales', options)
      validate_response(response)
    end

    def send_product(payload)
      product_hash = Vend::ProductBuilder.build(self, payload)
      options = {
        headers: headers,
        body: product_hash.to_json
      }

      response = self.class.post('/products', options)

      validate_response(response)
    end

    def update_inventory(payload)
      options = {headers: headers, body: payload.to_json }
      response = self.class.post('/products', options)
      # ignore deleted & system products
      if response['details'] == 'Cannot update a deleted product' ||
         response['details'] == 'You cannot edit a SYSTEM product'
        response
      else
        validate_response(response)
      end
    end

    def send_supplier(payload)
      supplier_hash = Vend::SupplierBuilder.build(self, payload)

      options = {
        headers: headers,
        body: supplier_hash.to_json
      }

      response = self.class.post('/supplier', options)

      validate_response(response)
    end

    def send_purchase_order(payload)
      purchase_order_hash = Vend::ConsignmentBuilder.build(payload)

      options = {
        headers: headers,
        body: purchase_order_hash.to_json
      }

      order_type = payload['type']
      # trap this error, critical as it will create a corrupt po in Vend
      if order_type == 'SUPPLIER' && payload['supplier_id'].nil?
        vendorname = payload['vendor']['name']
        raise "Supplier  #{vendorname} not found in Vend .. Please add first!"
      end

      consignment_id = payload['consignment_id']
      existing_line_items = []

      response = if consignment_id.nil?
                   self.class.post '/consignment', options
                 elsif payload['status'] == 'CANCELLED'
                   self.class.delete "/consignment/#{consignment_id}", options
                 else
                   existing_line_items = self.class.get("/consignment_product?consignment_id=#{consignment_id}", headers: headers)['consignment_products']
                   self.class.put "/consignment/#{consignment_id}", options
                 end

      if response.ok? && payload['status'] != 'CANCELLED'
        po_id = response['id']
        response['line_items'] = []
        existing_line_items.peach(3) do |line_item|
          line_item_response = self.class.delete "/consignment_product/#{line_item['id']}", headers: headers
          raise "Failed to remove line item: #{line_item_response}" unless line_item_response.ok?
        end

        line_items = payload['line_items']
        line_items.each_with_index.peach(3) do |line_item, index|
          if line_item['product_id']
            line_item_payload = {
              headers: headers,
              body: {
                consignment_id: po_id,
                product_id: line_item['product_id'],
                count: line_item['quantity'],
                received: line_item['received'] || 0,
                cost: line_item['unit_price'].to_i,
                sequence_number: index
              }.to_json
            }

            line_item_response = self.class.post('/consignment_product', line_item_payload)
            raise "Failed to add line item: #{line_item_response}" unless line_item_response.ok?
            response['line_items'] << line_item_response.to_h
          else
            raise "Missing line item: #{line_item} ,please add this item to vend!"
          end
        end
      end

      validate_response(response)
    end

    def send_new_customer(payload)
      customer_hash = Vend::CustomerBuilder.build_new_customer(self, payload)
      send_customer(customer_hash)
    end

    def send_update_customer(payload)
      customer_hash = Vend::CustomerBuilder.build_new_customer(self, payload)
      send_customer(customer_hash)
    end

    def send_customer(customer_hash)
      options = {
        headers: headers,
        body: customer_hash.to_json
      }

      response = self.class.post('/customers', options)
      validate_response(response)
    end

    def get_products_X(poll_product_timestamp)
      response = retrieve_products(poll_product_timestamp)

      (response['products'] || []).map { |product| Vend::ProductBuilder.parse_product(product) }
    end

    def get_outlets_X(poll_outlet_timestamp)
      response = retrieve_outlets(poll_outlet_timestamp)

      (response['outlets'] || []).map { |outlet| Vend::OutletBuilder.parse_outlet(outlet) }
    end

    def get_inventories(poll_inventory_timestamp)
      response = retrieve_products(poll_inventory_timestamp)

      inventories = []
      (response['products'] || []).each_with_index.map do |product, _i|
        (product['inventory'] || []).each do |inventory|
          inventories << {
            :id          => inventory['outlet_id'],
            'location'   => inventory['outlet_name'],
            'product_id' => product['id'],
            'quantity'   => inventory['count']
          }
        end
      end
      inventories
    end

    def get_orders(poll_order_timestamp)
      options = {
        headers: headers,
        query: { page_size: 10 }
      }
      options[:query][:since] = poll_order_timestamp if poll_order_timestamp

      orders = []
      paginate(options) do
        response = self.class.get('/register_sales', options)
        validate_response(response)

        orders = orders
                 .concat(response['register_sales'].to_a.map { |order| Vend::OrderBuilder.parse_order(order, self) })

        response
      end
      orders
    end

    def get_purchase_order(consignment_id:, name:)
      options = { headers: headers }
      response = self.class.get("/2.0/consignments/#{consignment_id}", options)
      status = response['data']['status']
      if response.ok? && status != 'CANCELLED'
        receipts = self.class.get('/consignment_product',
                                  options.merge(query: { consignment_id: consignment_id }))
        validate_response response
        validate_response receipts
        response.to_h.tap do |purchase_order|
          purchase_order['data'].merge!(
            line_items: receipts.to_h['consignment_products']
                                .sort_by { |line| line['sequence_number'] }
          )
        end
      else
        response
      end
    end

    def payment_type_id(payment_method)
      return @payments[payment_method] if @payments

      options = {
        headers: headers
      }

      response = self.class.get('/payment_types', options)
      validate_response(response)
      @payments = {}
      (response['payment_types'] || []).each_with_index.map do |payment_type, _i|
        @payments[payment_type['name']] = payment_type['id']
      end
      @payments[payment_method]
    end

    def find_outlet_by_id(outlet_id)
      outlets[outlet_id].slice('id', 'name')
    end

    def outlets
      @outlets ||= self.class.get('/outlets', headers: headers)['outlets'].index_by { |o| o['id'] }
    end

    def find_product_by_id(product_id)
      self.class.get("/2.0/products/#{product_id}", headers: headers)['data']
    end

    def find_supplier_by_id(supplier_id)
      self.class.get("/supplier/#{supplier_id}", headers: headers)
    end

    def product_id(product_id)
      return @products[product_id] if @products

      response = retrieve_products
      @products = {}
      (response['products'] || []).each_with_index.map do |product, _i|
        @products[product['handle']] = product['id']
      end
      @products[product_id]
    end

    def register_id(register_name)
      return @registers[register_name] if @registers

      options = {
        headers: headers
      }

      response = self.class.get('/registers', options)
      validate_response(response)
      @registers = {}
      (response['registers'] || []).each_with_index.map do |register, _i|
        @registers[register['name']] = register['id']
      end
      @registers[register_name]
    end

    def retrieve_customers(poll_customer_timestamp, email, id)
      options = {
        headers: headers,
        query: { page_size: 100 }
      }
      options[:query][:since] = poll_customer_timestamp if poll_customer_timestamp
      options[:query][:email] = email if email
      options[:query][:id]    = id if id

      customers = { 'customers' => [] }
      paginate(options) do
        response = self.class.get('/customers', options)
        validate_response(response)

        customers['customers'] = customers['customers'].concat(response['customers'])
        response
      end
      customers
    end

    def retrieve_outlets(poll_outlet_timestamp)
      options = {
        headers: headers,
        query: { page_size: 100 }
      }
      options[:query][:since] = poll_outlet_timestamp if poll_outlet_timestamp

      outlets = { 'outlets' => [] }
      paginate(options) do
        response = self.class.get('/outlets', options)
        validate_response(response)

        outlets['outlets'] = outlets['outlets'].concat(response['outlets'])
        response
      end
      outlets
    end

    def retrieve_products(poll_product_timestamp)
      options = {
        headers: headers,
        query: { page_size: 100 }
      }
      options[:query][:since] = poll_product_timestamp if poll_product_timestamp

      products = { 'products' => [] }
      paginate(options) do
        response = self.class.get('/products', options)
        validate_response(response)

        products['products'] = products['products'].concat(response['products'])
        response
      end
      products
    end

    def get_discount_product
      unless @discount_product
        options = {
          headers: headers,
          query: { handle: 'vend-discount', sku: 'vend-discount' }
        }
        response = self.class.get('/products', options)

        validate_response(response)
        @discount_product = response['products'][0]['id']
      end
      @discount_product
    end

    def get_shipping_product
      unless @shipping_product
        options = {
          headers: headers,
          query: { handle: 'shipping', sku: 'shipping' }
        }
        response = self.class.get('/products', options)

        validate_response(response)
        @shipping_product = response['products'][0]['id'] unless response['products'][0].nil?
      end
      @shipping_product
    end

    def get_sku_product(sku)
        options = {
          headers: headers,
          query: { type: 'products',
            sku: sku
           }
        }
        response = self.class.get('/2.0/search', options)

        validate_response(response)
        @sku_product = response['data']

    end

    def delete_product(id)
        response = self.class.delete "/products/#{id}", headers: headers
        validate_response(response)
    end

    def upload_product_image(id,url)
      temp=open(url)
      if temp.present?
          options = {headers: multi_header, query: {image: File.new(temp)}}
          response = self.class.post "/2.0/products/#{id}/actions/image_upload" , options
          validate_response(response)
      end
  end

    private

    def paginate(options)
      begin
        response = yield

        if response.key?('pagination') && response['pagination']['page'] < response['pagination']['pages']
          options[:query][:page] = response['pagination']['page'] + 1
          has_more_pages = true
        else
          has_more_pages = false
        end
      end while has_more_pages
    end

    def validate_response(response)
      raise VendEndpointError, response if Vend::ErrorParser.response_has_errors?(response)
      response
    end
  end
end