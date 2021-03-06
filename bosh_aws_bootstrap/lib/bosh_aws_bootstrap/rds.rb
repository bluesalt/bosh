require "securerandom"

module Bosh
  module Aws
    class RDS
      DEFAULT_RDS_OPTIONS = {
        :allocated_storage => 5,
        :db_instance_class => "db.t1.micro",
        :engine => "mysql",
        :multi_az => true
      }

      def initialize(credentials)
        @credentials = credentials
      end

      def create_database(name, subnet_ids, vpc_id, vpc_cidr, options = {})
        create_subnet_group(name, subnet_ids) unless subnet_group_exists?(name)
        create_security_group(name, vpc_id, vpc_cidr) unless security_group_exists?(name)

        # symbolize options keys
        options = options.inject({}) { |memo, (k,v)| memo[k.to_sym] = v; memo }

        creation_options = DEFAULT_RDS_OPTIONS.merge(options)
        creation_options[:db_instance_identifier] = name
        creation_options[:db_name] = name
        creation_options[:db_security_groups] = [name]
        creation_options[:db_subnet_group_name] = name
        creation_options[:master_username] ||= generate_user
        creation_options[:master_user_password] ||= generate_password
        response = aws_rds_client.create_db_instance(creation_options)
        response.data.merge(:master_user_password => creation_options[:master_user_password])
      end

      def databases
        aws_rds.db_instances
      end

      def database(name)
        databases.find { |v| v.name == name }
      end

      def database_exists?(name)
        !database(name).nil?
      end

      def delete_databases
        databases.each {|db| db.delete(skip_final_snapshot: true) unless db.db_instance_status == "deleting" }
      end

      def database_names
        databases.inject({}) do |memo, db_instance|
          memo[db_instance.id] = db_instance.name
          memo
        end
      end

      def subnet_group_exists?(name)
        aws_rds_client.describe_db_subnet_groups(:db_subnet_group_name => name)
        return true
      rescue AWS::RDS::Errors::DBSubnetGroupNotFoundFault
        return false
      end

      def create_subnet_group(name, subnet_ids)
        aws_rds_client.create_db_subnet_group(
          :db_subnet_group_name => name,
          :db_subnet_group_description => name,
          :subnet_ids => subnet_ids
        )
      end

      def subnet_group_names
        aws_rds_client.describe_db_subnet_groups.data[:db_subnet_groups].map { |sg| sg[:db_subnet_group_name] }
      end

      def delete_subnet_group(name)
        aws_rds_client.delete_db_subnet_group(:db_subnet_group_name => name)
      end

      def delete_subnet_groups
        subnet_group_names.each { |name| delete_subnet_group(name) }
      end

      def security_group_exists?(name)
        aws_rds_client.describe_db_security_groups(:db_security_group_name => name)
        return true
      rescue AWS::RDS::Errors::DBSecurityGroupNotFound
        return false
      end

      def create_security_group(name, vpc_id, cidrip)
        aws_rds_client.create_db_security_group(
          :db_security_group_name => name,
          :db_security_group_description => name,
          :ec2_vpc_id => vpc_id
        )

        aws_rds_client.authorize_db_security_group_ingress(:db_security_group_name => name, :cidrip => cidrip)
      end

      def security_group_names
        aws_rds_client.describe_db_security_groups.data[:db_security_groups].map { |sg| sg[:db_security_group_name] }
      end

      def delete_security_group(name)
        aws_rds_client.delete_db_security_group(:db_security_group_name => name)
      end

      def delete_security_groups
        security_group_names.each do |name|
          delete_security_group(name) unless name == "default"
        end
      end

      def aws_rds
        @aws_rds ||= ::AWS::RDS.new(@credentials)
      end

      def aws_rds_client
        @aws_rds_client ||= ::AWS::RDS::Client.new(@credentials)
      end

      private

      def generate_user
        generate_credential("u", 7)
      end

      def generate_password
        generate_credential("p", 16)
      end

      def generate_credential(prefix, length)
        "#{prefix}#{SecureRandom.hex(length)}"
      end
    end
  end
end
