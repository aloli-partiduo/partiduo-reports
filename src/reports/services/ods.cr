# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/crc32"

module Reports
  # Classeur OpenDocument (ODS, ISO/IEC 26300) d'un tableau : `mimetype`
  # non compressé en tête de l'archive, manifeste, styles des titres et des
  # totaux, montants typés (`office:value-type`) pour que le tableur les
  # additionne. Écrit à la main : pas de dépendance. Interne.
  module Ods
    MIMETYPE = "application/vnd.oasis.opendocument.spreadsheet"

    def self.build(sheet : Sheets::Sheet) : Bytes
      io = IO::Memory.new
      Compress::Zip::Writer.open(io) do |zip|
        entry = Compress::Zip::Writer::Entry.new("mimetype")
        entry.compression_method = Compress::Zip::CompressionMethod::STORED
        entry.crc32 = Digest::CRC32.checksum(MIMETYPE)
        entry.compressed_size = entry.uncompressed_size = MIMETYPE.bytesize.to_u32
        zip.add(entry, MIMETYPE)
        zip.add("META-INF/manifest.xml", manifest)
        zip.add("styles.xml", styles)
        zip.add("content.xml", content(sheet))
      end
      io.to_slice
    end

    private def self.manifest : String
      <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">
         <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="#{MIMETYPE}"/>
         <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>
         <manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/>
        </manifest:manifest>
        XML
    end

    private def self.styles : String
      <<-XML
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.2"/>
        XML
    end

    NAMESPACES = %(xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" ) +
                 %(xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" ) +
                 %(xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" ) +
                 %(xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" ) +
                 %(xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" ) +
                 %(xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0")

    private def self.content(sheet : Sheets::Sheet) : String
      String.build do |io|
        io << %(<?xml version="1.0" encoding="UTF-8"?>\n)
        io << %(<office:document-content #{NAMESPACES} office:version="1.2">)
        io << %(<office:automatic-styles>)
        io << %(<number:number-style style:name="N0"><number:number number:decimal-places="#{sheet.decimals}" number:min-integer-digits="1" number:grouping="true"/></number:number-style>)
        io << %(<style:style style:name="amount" style:family="table-cell" style:data-style-name="N0"/>)
        io << %(<style:style style:name="strong" style:family="table-cell"><style:text-properties fo:font-weight="bold"/></style:style>)
        io << %(<style:style style:name="strong_amount" style:family="table-cell" style:data-style-name="N0"><style:text-properties fo:font-weight="bold"/></style:style>)
        io << %(<style:style style:name="wide" style:family="table-column"><style:table-column-properties style:column-width="8cm"/></style:style>)
        io << %(<style:style style:name="narrow" style:family="table-column"><style:table-column-properties style:column-width="3cm"/></style:style>)
        io << %(</office:automatic-styles><office:body><office:spreadsheet>)
        io << %(<table:table table:name="#{escape(sheet.title[0, 31])}">)
        sheet.columns.each_with_index do |_, index|
          io << %(<table:table-column table:style-name="#{index.zero? ? "wide" : "narrow"}"/>)
        end
        row(io, [Sheets::Cell.new(sheet.title)], "heading", 2)
        sheet.subtitle.each { |line| row(io, [Sheets::Cell.new(line)], "line", 2) }
        row(io, sheet.columns.map { |column| Sheets::Cell.new(column.title) }, "heading", 2)
        sheet.rows.each { |item| row(io, item.cells, item.style, sheet.decimals, item.indent) }
        io << %(</table:table></office:spreadsheet></office:body></office:document-content>)
      end
    end

    private def self.row(io : IO, cells : Array(Sheets::Cell), style : String, decimals : Int32, indent : Int32 = 0) : Nil
      strong = style != "line"
      io << "<table:table-row>"
      cells.each_with_index do |cell, index|
        if amount = cell.amount
          value = Numbers.raw(amount, decimals)
          io << %(<table:table-cell table:style-name="#{strong ? "strong_amount" : "amount"}" office:value-type="float" office:value="#{value}"><text:p>#{value}</text:p></table:table-cell>)
        else
          text = index.zero? && indent > 0 ? "#{"  " * indent}#{cell.text}" : cell.text
          style_attribute = strong ? %( table:style-name="strong") : ""
          io << %(<table:table-cell#{style_attribute} office:value-type="string"><text:p>#{escape(text)}</text:p></table:table-cell>)
        end
      end
      io << "</table:table-row>"
    end

    def self.escape(text : String) : String
      text.gsub(/[\x00-\x08\x0B\x0C\x0E-\x1F]/, "").gsub('&', "&amp;").gsub('<', "&lt;").gsub('>', "&gt;").gsub('"', "&quot;")
    end
  end
end
