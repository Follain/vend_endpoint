require 'digest'

module Vend
  class OrderBuilder
    class << self
      def order_placed(client, payload)
        hash = {
            'register_id'            => ENV.fetch('VEND_ECOMM_REGISTER_ID'),
            'customer_id'            => customer_id(client, payload),
            'sale_date'              => payload['placed_on'],
            'total_price'            => payload['totals']['order'].to_f - payload['totals']['tax'].to_f,
            'total_tax'              => payload['totals']['tax'].to_f,
            'tax_name'               => 'TAX',
            'status'                 => payload['status'],
            'invoice_number'         => payload['id'],
            'note'                   => nil,
            'register_sale_payments' => payments(client, payload)
        }

        hash.merge!('id' => payload['vend_id']) if payload['vend_id'].present?

        products = products_of_order(client, payload)

        discount_total = discount_total(payload).to_f
        products << add_discount_product(payload, hash['register_id'], client) unless discount_total.zero?

        shipping = add_shipping_product(payload, hash['register_id'], client) if payload['totals']['shipping']
        products << shipping if shipping

        hash['register_sale_products']= products

        hash
      end

      def discount_total(payload)
        payload['adjustments'].select do |adjustment|
          'discount' == adjustment['name']
        end.sum do |adjustment|
          -adjustment['value']
        end + line_item_promo_totals(payload)
      end

      def line_item_promo_totals(payload)
        (payload['line_items'] || []).sum do |line_item|
          line_item['promo_total'].to_f
        end
      end


      def products_of_order(client, payload)
        (payload['line_items'] || []).each_with_index.map do |line_item, i|
          quantity = line_item['quantity'].to_i
          promo_per_unit = line_item['promo_total'].to_f * -1 / quantity
          {
            'product_id' => line_item['product_id'].to_s,
            'quantity'   => line_item['quantity'],
            'price'      => line_item['price'].to_f - promo_per_unit,
            'discount'   => promo_per_unit,
            'tax'        => line_item['additional_tax_total'].to_f / quantity,
            'tax_total'  => line_item['additional_tax_total'].to_f,
            'attributes' => [
                    {
                        'name'  => 'line_note',
                        'value' => line_item['name']
                    }]
          }
        end
      end

      #Yeah, weird, but it's how Vend treat discount
      #https://developers.vendhq.com/documentation/api/0.x/register-sales.html#discounts
      def add_discount_product(payload, register_id, client)
        discount_total = self.discount_total(payload)

        {
          'product_id'=> client.get_discount_product,
          'register_id'=> ENV.fetch('VEND_ECOMM_REGISTER_ID'),
          'sequence'=> '0',
          'handle'=> 'vend-discount',
          'sku'=> 'vend-discount',
          'name'=> 'Discount',
          'quantity'=> -1,
          'price'=> discount_total,
          'price_set'=> 1,
          'discount'=> 0,
          'loyalty_value'=> 0,
          'tax' => 0,
          'tax_id' => nil,
          'tax_rate' => 0,
          'tax_total' => 0,
          'price_total'=> -discount_total,
          'display_retail_price_tax_inclusive'=> '1',
          'status'=> 'CONFIRMED'
        }
      end

      def add_shipping_product(payload, register_id, client)
        return nil if client.get_shipping_product.nil?

        {
          'product_id'=> client.get_shipping_product,
          'register_id'=> ENV.fetch('VEND_ECOMM_REGISTER_ID'),
          'sequence'=> '0',
          'handle'=> 'shipping',
          'sku'=> 'shipping',
          'name'=> 'Shipping',
          'quantity'=> 1,
          'price'=> payload['totals']['shipping'],
          'price_set'=> 1,
          'discount'=> 0,
          'loyalty_value'=> 0,
          'price_total'=> payload['totals']['shipping'],
          'status'=> 'CONFIRMED'
        }
      end

      def payments(client, payload)
        (payload['payments'] || []).each_with_index.map do |payment, i|
          {
            'id'                       => nil,
            'retailer_payment_type_id' => client.payment_type_id('x' + payment['payment_method']),
            'payment_date'             => payload['placed_on'],
            'amount'                   => payment['amount'].to_f
          }
        end
      end

      def parse_order(vend_order, client)
        adjustments = [{
                'name'  => 'Tax',
                'value' => vend_order['total_tax']
              }]
        shipment_adjust = build_shipping_from_items(vend_order)
        adjustments << shipment_adjust if shipment_adjust
        shipment_amount = shipment_adjust['value'] if shipment_adjust

        discount_adjust = build_discount_from_items(vend_order)
        adjustments << discount_adjust if discount_adjust
        discount_amount = discount_adjust['value'] if discount_adjust

        hash = {
            :id              => vend_order['id'],
            'customer_id'    => vend_order['customer_id'],
            'register_id'    => vend_order['register_id'],
            'status'         => vend_order['status'],
            'invoice_number' => vend_order['invoice_number'],
            'placed_on'      => vend_order['sale_date'],
            'updated_at'     => vend_order['updated_at'],
            'totals'=> {
              'item'    => vend_order['totals']['total_price'].to_f - shipment_amount.to_f - (discount_amount.to_f*-1),
              'order'   => vend_order['totals']['total_payment'],
              'tax'     => vend_order['total_tax'],
              'payment' => vend_order['totals']['total_payment']
            },
            'line_items'  => parse_items(vend_order, client),
            'adjustments' => adjustments,
            'payments'    => parse_payments(vend_order)
        }
        hash['totals']['shipping'] = shipment_amount.to_f if shipment_amount
        hash['totals']['discount'] = discount_amount.to_f if discount_amount

        customer = client.retrieve_customers(nil, nil, vend_order['customer_id'])['customers'][0]
        hash.merge!(Vend::CustomerBuilder.parse_customer_for_order(customer)) if customer
        hash
      end

      def parse_items(vend_order, client)
        itens = (vend_order['register_sale_products'] || []).
            reject{|item| item['product_id'] == client.get_shipping_product || item['product_id'] == client.get_discount_product}

        itens.each_with_index.map do |line_item, i|
          {
            'id'         => line_item['id'],
            'product_id' => line_item['product_id'],
            'name'       => line_item['name'].split("/")[0],
            'quantity'   => line_item['quantity'].to_f,
            'price'      => line_item['price'].to_f
          }
        end
      end

      def parse_payments(vend_order)
        (vend_order['register_sale_payments'] || []).each_with_index.map do |payment, i|
          {
            'id'             => payment['id'],
            'number'         => payment['payment_type_id'],
            'status'         => vend_order['status'],
            'amount'         => payment['amount'].to_f,
            'payment_method' => payment['name']
          }
        end
      end

      def customer_id(client, payload)
        customer = client.retrieve_customers(nil, payload['email'], nil)

        if customer['customers'][0].nil?
          customer = client.send_new_customer(build_customer_based_on_order(payload))
          customer['customer']['id']
        else
          customer['customers'][0]['id']
        end
      end

      def build_customer_based_on_order(payload)
        #gift card orders do not always have address
        if payload['shipping_address'].present?
        {
          'firstname'        => payload['shipping_address']['firstname'],
          'lastname'         => payload['shipping_address']['lastname'],
          'email'            => payload['email'],
          'shipping_address' => payload['shipping_address'],
          'billing_address'  => payload['shipping_address']
        }
        else
        {
          'firstname'        => nil,
          'lastname'         => nil,
          'email'            => payload['email'],
          'shipping_address' => nil,
          'billing_address'  => nil
        }
        end
    end

      def build_shipping_from_items(vend_order)
        shipping_adjstment = nil
        (vend_order['register_sale_products'] || []).each_with_index.map do |line_item, i|
          if line_item['name'] == 'shipping'
            shipping_adjstment = {
                                  'name'  => 'Shipping',
                                  'value' => line_item['price'].to_f
                                 }
          end
        end
        shipping_adjstment
      end

      def build_discount_from_items(vend_order)
        discount_adjstment = nil
        (vend_order['register_sale_products'] || []).each_with_index.map do |line_item, i|
          if line_item['name'] == 'Discount'
            discount_adjstment = {
                                  'name'  => 'Discount',
                                  'value' => line_item['price'].to_f
                                 }
          end
        end
        discount_adjstment
      end

    end
  end
end
