#
# Copyright (c) 2014--2015 Red Hat Inc.
#
# This software is licensed to you under the GNU General Public License,
# version 3 (GPLv3). There is NO WARRANTY for this software, express or
# implied, including the implied warranties of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE. You should have received a copy of GPLv3
# along with this software; if not, see http://www.gnu.org/licenses/gpl.txt
#
require 'smart_proxy_openscap/openscap_lib'

module Proxy::OpenSCAP
  HTTP_ERRORS = [
    EOFError,
    Errno::ECONNRESET,
    Errno::EINVAL,
    Errno::ECONNREFUSED,
    Net::HTTPBadResponse,
    Net::HTTPHeaderSyntaxError,
    Net::ProtocolError,
    Timeout::Error
  ]

  class Api < ::Sinatra::Base
    include ::Proxy::Log
    helpers ::Proxy::Helpers
    authorize_with_ssl_client

    before '(/arf/*|/oval_report/*)' do
      begin
        @cn = Proxy::OpenSCAP::common_name request
      rescue Proxy::Error::Unauthorized => e
        log_halt 403, "Client authentication failed: #{e.message}"
      end
      @reported_at = Time.now.to_i
    end

    post "/arf/:policy" do
      policy = params[:policy]

      begin
        post_to_foreman = ForemanForwarder.new.post_arf_report(@cn, policy, @reported_at, request.body.string, Proxy::OpenSCAP::Plugin.settings.timeout)
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, @cn, post_to_foreman['id'], @reported_at).store_archive(request.body.string)
        post_to_foreman.to_json
      rescue Proxy::OpenSCAP::StoreReportError => e
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.failed_dir, @cn, post_to_foreman['id'], @reported_at).store_failed(request.body.string)
        logger.error "Failed to save Report in reports directory (#{Proxy::OpenSCAP::Plugin.settings.reportsdir}). Failed with: #{e.message}.
                      Saving file in #{Proxy::OpenSCAP::Plugin.settings.failed_dir}. Please copy manually to #{Proxy::OpenSCAP::Plugin.settings.reportsdir}"
        { :result => 'Storage failure on proxy, see proxy logs for details' }.to_json
      rescue Proxy::OpenSCAP::OpenSCAPException => e
        error = "Failed to parse Arf Report, moving to #{Proxy::OpenSCAP::Plugin.settings.corrupted_dir}"
        logger.error error
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.corrupted_dir, cn, policy, @reported_at).store_corrupted(request.body.string)
        { :result => (error << ' on proxy') }.to_json
      rescue *HTTP_ERRORS => e
        ### If the upload to foreman fails then store it in the spooldir
        msg = "Failed to upload to Foreman, saving in spool. Failed with: #{e.message}"
        logger.error msg
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.spooldir, @cn, policy, @reported_at).store_spool(request.body.string)
        { :result => msg }.to_json
      rescue Proxy::OpenSCAP::StoreSpoolError => e
        log_halt 500, e.message
      rescue Proxy::OpenSCAP::ReportUploadError => e
        { :result => e.message }.to_json
      end
    end

    post "/oval_report/:oval_policy_id" do
      json = OvalReportParser.new.as_json(request.body.string)

      OvalReportStorageFs.new(
        Proxy::OpenSCAP::Plugin.settings.reportsdir,
        params[:oval_policy_id],
        @cn,
        @reported_at
      ).store_report(json)

      { :reported_at => Time.at(@reported_at) }.to_json
    rescue Proxy::OpenSCAP::StoreReportError => e
      logger.error e
      { :result => 'Storage failure on proxy, see proxy logs for details.' }.to_json
    rescue Nokogiri::XML::SyntaxError => e
      logger.error e
      { :result => 'Failed to parse OVAL report, see proxy logs for details' }.to_json
    rescue Proxy::OpenSCAP::ReportUploadError, Proxy::OpenSCAP::ReportDecompressError => e
      { :result => e.message }.to_json
    end


    get "/arf/:id/:cname/:date/:digest/xml" do
      content_type 'application/x-bzip2'
      begin
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, params[:cname], params[:id], params[:date]).get_arf_xml(params[:digest])
      rescue FileNotFound => e
        log_halt 500, "Could not find requested file, #{e.message}"
      end
    end

    delete "/arf/:id/:cname/:date/:digest" do
      begin
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.reportsdir, params[:cname], params[:id], params[:date]).delete_arf_file
      rescue FileNotFound => e
        logger.debug "Could not find requested file, #{e.message} - Assuming deleted"
      end
    end

    get "/arf/:id/:cname/:date/:digest/html" do
      begin
        Proxy::OpenSCAP::OpenscapHtmlGenerator.new(params[:cname], params[:id], params[:date], params[:digest]).get_html
      rescue FileNotFound => e
        log_halt 500, "Could not find requested file, #{e.message}"
      rescue OpenSCAPException => e
        log_halt 500, "Could not generate report in HTML"
      end
    end

    get "/policies/:policy_id/content/:digest" do
      content_type 'application/xml'
      begin
        Proxy::OpenSCAP::FetchScapFile.new(:scap_content)
          .fetch(params[:policy_id], params[:digest], Proxy::OpenSCAP::Plugin.settings.contentdir)
      rescue *HTTP_ERRORS => e
        log_halt e.response.code.to_i, file_not_found_msg
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    get "/policies/:policy_id/content" do
      content_type 'application/xml'
      logger.warn 'DEPRECATION WARNING: /policies/:policy_id/content/:digest should be used, please update foreman_openscap'
      begin
        Proxy::OpenSCAP::FetchScapFile.new(:scap_content)
          .fetch(params[:policy_id], 'scap_content', Proxy::OpenSCAP::Plugin.settings.contentdir)
      rescue *HTTP_ERRORS => e
        log_halt e.response.code.to_i, file_not_found_msg
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    get "/policies/:policy_id/tailoring/:digest" do
      content_type 'application/xml'
      begin
        Proxy::OpenSCAP::FetchScapFile.new(:tailoring_file)
          .fetch(params[:policy_id], params[:digest], Proxy::OpenSCAP::Plugin.settings.tailoring_dir)
      rescue *HTTP_ERRORS => e
        log_halt e.response.code.to_i, file_not_found_msg
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    post "/scap_content/policies" do
      begin
        Proxy::OpenSCAP::ProfilesParser.new.profiles('scap_content', request.body.string)
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    post "/tailoring_file/profiles" do
      begin
        Proxy::OpenSCAP::ProfilesParser.new.profiles('tailoring_file', request.body.string)
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    post "/scap_file/validator/:type" do
      validate_scap_file params
    end

    post "/scap_content/validator" do
      logger.warn "DEPRECATION WARNING: '/scap_content/validator' will be removed in the future. Use '/scap_file/validator/scap_content' instead"
      params[:type] = 'scap_content'
      validate_scap_file params
    end

    post "/scap_content/guide/?:policy?" do
      begin
        Proxy::OpenSCAP::PolicyParser.new(params[:policy]).guide(request.body.string)
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    get "/spool_errors" do
      begin
        Proxy::OpenSCAP::StorageFs.new(Proxy::OpenSCAP::Plugin.settings.corrupted_dir, nil, nil, nil).spool_errors.to_json
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    private

    def validate_scap_file(params)
      begin
        Proxy::OpenSCAP::ContentParser.new(params[:type]).validate(request.body.string)
      rescue *HTTP_ERRORS => e
        log_halt 500, e.message
      rescue StandardError => e
        log_halt 500, "Error occurred: #{e.message}"
      end
    end

    def file_not_found_msg
      "File not found on Foreman. Wrong policy id?"
    end
  end
end
