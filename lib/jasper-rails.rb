#
# Copyright (C) 2012 Marlus Saraiva, Rodrigo Maia
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require "jasper-rails/version"
require "rails"
require "rjb"
require "action_controller/metal/responder"

if Mime::Type.lookup_by_extension("pdf").nil?
  Mime::Type.register "application/pdf", :pdf
end

module JasperRails

  class << self
    attr_accessor :config
  end

  classpath = '.'
  Dir["#{File.dirname(__FILE__)}/java/*.jar"].each do |jar|
    classpath << File::PATH_SEPARATOR + File.expand_path(jar)
  end

  Dir["lib/*.jar"].each do |jar|
    classpath << File::PATH_SEPARATOR + File.expand_path(jar)
  end

  Rjb::load( classpath, ['-Djava.awt.headless=true','-Xms128M', '-Xmx256M'] )

  Locale                      = Rjb::import 'java.util.Locale'
  JRException                 = Rjb::import 'net.sf.jasperreports.engine.JRException'
  JasperCompileManager        = Rjb::import 'net.sf.jasperreports.engine.JasperCompileManager'
  JasperExportManager         = Rjb::import 'net.sf.jasperreports.engine.JasperExportManager'
  JasperFillManager           = Rjb::import 'net.sf.jasperreports.engine.JasperFillManager'
  JasperPrint                 = Rjb::import 'net.sf.jasperreports.engine.JasperPrint'
  JRXmlUtils                  = Rjb::import 'net.sf.jasperreports.engine.util.JRXmlUtils'
  JREmptyDataSource           = Rjb::import 'net.sf.jasperreports.engine.JREmptyDataSource'
  # This is here to avoid the "already initialized constant QUERY_EXECUTER_FACTORY_PREFIX" warnings.
  JRXPathQueryExecuterFactory = silence_warnings{Rjb::import 'net.sf.jasperreports.engine.query.JRXPathQueryExecuterFactory'}
  InputSource                 = Rjb::import 'org.xml.sax.InputSource'
  StringReader                = Rjb::import 'java.io.StringReader'
  HashMap                     = Rjb::import 'java.util.HashMap'
  ByteArrayInputStream        = Rjb::import 'java.io.ByteArrayInputStream'
  JavaString                  = Rjb::import 'java.lang.String'
  JFreeChart                  = Rjb::import 'org.jfree.chart.JFreeChart'

  JRRtfExporter               = Rjb::import 'net.sf.jasperreports.engine.export.JRRtfExporter'
  JRXlsExporter               = Rjb::import 'net.sf.jasperreports.engine.export.JRXlsExporter'
  JRExporterParameter         = Rjb::import 'net.sf.jasperreports.engine.JRExporterParameter'
  ByteArrayOutputStream       = Rjb::import 'java.io.ByteArrayOutputStream'
  # Default report params
  self.config = {
    :report_params=>{
      :REPORT_LOCALE => Locale.new('en', 'US'),
      :XML_LOCALE => Locale.new('en', 'US'),
      :XML_DATE_PATTERN => 'yyyy-MM-dd'
    }
  }

  # Returns the value without conversion when it's converted to Java Types.
  # When isn't a Rjb class, returns a Java String of it.
  def self.parameter_value_of(param)
    # Using Rjb::import('java.util.HashMap').new, it returns an instance of
    # Rjb::Rjb_JavaProxy, so the Rjb_JavaProxy parent is the Rjb module itself.
    param.class.parent == Rjb ? param : JavaString.new(param.to_s)
  end

  class JasperAbstractHelper
    def export_report jasper_print
      raise "error"
    end

    def self.prepare_report(jasper_file, data_source, parameters, options)
      options ||= {}
      parameters ||= {}
      jrxml_file  = jasper_file.sub(/\.jasper$/, ".jrxml")

      # Converting default report params to java HashMap
      jasper_params = HashMap.new
      JasperRails.config[:report_params].each do |k,v|
        jasper_params.put(k, v)
      end

      # Convert the ruby parameters' hash to a java HashMap, but keeps it as
      # default when they already represent a JRB entity.
      # Pay attention that, for now, all other parameters are converted to string!
      parameters.each do |key, value|
        jasper_params.put(JavaString.new(key.to_s), JasperRails::parameter_value_of(value))
      end

      # Compile it, if needed
      if !File.exist?(jasper_file) || (File.exist?(jrxml_file) && File.mtime(jrxml_file) > File.mtime(jasper_file))
        JasperCompileManager.compileReportToFile(jrxml_file, jasper_file)
      end

      # Fill the report
      if data_source
        input_source = InputSource.new
        input_source.setCharacterStream(StringReader.new(data_source.to_xml(options).to_s))
        data_document = silence_warnings do
          # This is here to avoid the "already initialized constant DOCUMENT_POSITION_*" warnings.
          JRXmlUtils._invoke('parse', 'Lorg.xml.sax.InputSource;', input_source)
        end

        jasper_params.put(JRXPathQueryExecuterFactory.PARAMETER_XML_DATA_DOCUMENT, data_document)

        JasperFillManager.fillReport(jasper_file, jasper_params)
      else
        JasperFillManager.fillReport(jasper_file, jasper_params, JREmptyDataSource.new)
      end
    end
  end

  class JasperPdfHelper < JasperAbstractHelper
    def export_report jasper_print
      JasperExportManager._invoke('exportReportToPdf', 'Lnet.sf.jasperreports.engine.JasperPrint;', jasper_print)
    end
  end

  class JasperRtfHelper < JasperAbstractHelper
    def export_report jasper_print
      exporter = JRRtfExporter.new
      rtf_stream = ByteArrayOutputStream.new
      exporter.setParameter(JRExporterParameter.JASPER_PRINT, jasper_print)
      exporter.setParameter(JRExporterParameter.OUTPUT_STREAM, rtf_stream)
      # exporter.setParameter(JRExporterParameter.OUTPUT_FILE_NAME, "report.rtf" )
      exporter.exportReport()
      rtf_stream.toByteArray()
    end
  end

  class JasperXlsHelper < JasperAbstractHelper
    def export_report jasper_print
      exporter = JRXlsExporter.new
      xls_stream = ByteArrayOutputStream.new
      exporter.setParameter(JRExporterParameter.JASPER_PRINT, jasper_print)
      exporter.setParameter(JRExporterParameter.OUTPUT_STREAM, xls_stream)
      # exporter.setParameter(JRExporterParameter.OUTPUT_FILE_NAME, "report.xls" )
      exporter.exportReport()
      xls_stream.toByteArray()
    end
  end

  class ActionController::Responder
    def to_report(type)
      jasper_file = "#{Rails.root.to_s}/app/views/#{controller.controller_path}/#{controller.action_name}.jasper"

      params = {}
      controller.instance_variables.each do |v|
        params[v.to_s[1..-1]] = controller.instance_variable_get(v)
      end

      begin
        reports_helper = case type
        when Mime::PDF
          JasperRails::JasperPdfHelper.new
        when Mime::RTF
          JasperRails::JasperRtfHelper.new
        when Mime::XLS
          JasperRails::JasperXlsHelper.new
        else
          raise "error"
        end

        jasper_print = JasperRails::JasperAbstractHelper.prepare_report(jasper_file, resource, params, options)
        controller.send_data reports_helper.export_report(jasper_print), :type => type
      rescue Exception=>e
        if e.respond_to? 'printStackTrace'
          ::Rails.logger.error e.message
          e.printStackTrace
        else
          ::Rails.logger.error e.message + "\n " + e.backtrace.join("\n ")
        end
        raise e
      end

    end

    def to_pdf
      to_report Mime::PDF
    end

    def to_rtf
      to_report Mime::RTF
    end

    def to_xls
      to_report Mime::XLS
    end
  end
end
