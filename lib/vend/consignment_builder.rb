
# frozen_string_literal: true

module Vend
  ConsignmentBuilder = Struct.new(:payload) do
    def self.build(payload)
      new(payload).to_hash
    end

    def to_hash
      {
        name: name,
        reference: payload['id'],
        alt_po_number: payload['id'],
        due_at: payload['due_date'],
        consignment_date: payload['orderdate'],
        outlet_id: payload['location_id'],
        source_outlet_id: payload['source_location_id'],
        supplier_id: payload['supplier_id'],
        type: payload['type'],
        status: payload['status']
      }
    end

    def name
      @name = if payload['txn_type'].in? %W(RECEIPT SHIPMENT TRANSFER)
                payload['name']
              else "[#{payload['id']}] #{payload['name']}".squish
              end
    end
  end
end
