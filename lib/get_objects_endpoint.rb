module GetObjectsEndpoint
  def get_endpoint(name)
    name = name.to_s
    method = "get_#{name.pluralize}"
    post "/#{method}" do
      begin
        code = 200
        response = client.send(method, since: payload['after_version'])
        objects = response['data']
        set_summary "Retrieved #{objects.size} #{name.pluralize} from Vend"
        add_parameter :max_version, response['version']['max']
        if objects.any?
            objects.each_with_index do |object, index|
            #flip between transfers, purchase orders & stocktake .... vend only has one exit point
                if name == 'purchase_order'
                   po_type =object['type']
                   case   po_type
                     when 'OUTLET'
                          add_object 'transfer_order', object
                     when 'RETURN'
                          add_object 'rtv', object
                     when 'SUPPLIER'
                          add_object 'purchase_order', object
                     when 'STOCKTAKE'
                          add_object 'inventory_adjustment', object
                     end
                else
                  #if page is full request another poll request
                  if index== objects.size-1 && objects.size >= 24
                    add_object name, object.merge({poll: 'true'})
                  else
                    add_object name, object
                  end
              end
            end
        else
          add_value name.pluralize, []
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
  end
end
