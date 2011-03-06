# encoding: utf-8

# core/text/formatted/arranger.rb : Implements a data structure for 2-stage
#                                   processing of lines of formatted text
#
# Copyright February 2010, Daniel Nelson. All Rights Reserved.
#
# This is free software. Please see the LICENSE and COPYING files for details.

module Prawn
  module Core
    module Text
      module Formatted #:nodoc:

        class Arranger #:nodoc:
          attr_reader :max_line_height
          attr_reader :max_descender
          attr_reader :max_ascender

          # The following present only for testing purposes
          attr_reader :unconsumed
          attr_reader :consumed
          attr_reader :fragments
          attr_reader :current_format_state

          def initialize(document)
            @document = document
            @fragments = []
            @unconsumed = []
          end

          def space_count
            if @unfinalized_line
              raise "Lines must be finalized before calling #space_count"
            end
            @fragments.inject(0) do |sum, fragment|
              sum + fragment.space_count
            end
          end

          def line_width
            if @unfinalized_line
              raise "Lines must be finalized before calling #line_width"
            end
            @fragments.inject(0) do |sum, fragment|
              sum + fragment.width
            end
          end

          def line
            if @unfinalized_line
              raise "Lines must be finalized before calling #line"
            end
            @fragments.collect do |fragment|
              if ruby_18 { true }
                fragment.text
              else
                fragment.text.dup.force_encoding("utf-8")
              end
            end.join
          end

          def finalize_line
            @unfinalized_line = false
            omit_trailing_whitespace_from_line_width
            @fragments = []
            @consumed.each do |hash|
              text = hash[:text]
              format_state = hash.dup
              format_state.delete(:text)
              fragment = Prawn::Text::Formatted::Fragment.new(text,
                                                              format_state,
                                                              @document)
              @fragments << fragment
              set_fragment_measurements(fragment)
              set_line_measurement_maximums(fragment)
            end
          end

          def format_array=(array)
            initialize_line
            @unconsumed = []
            array.each do |hash|
              hash[:text].scan(/[^\n]+|\n/) do |line|
                @unconsumed << hash.merge(:text => line)
              end
            end
          end

          def initialize_line
            @unfinalized_line = true
            @max_line_height = 0
            @max_descender = 0
            @max_ascender = 0

            @consumed = []
            @fragments = []
          end

          def finished?
            @unconsumed.length == 0
          end

          def next_string
            unless @unfinalized_line
              raise "Lines must not be finalized when calling #next_string"
            end
            hash = @unconsumed.shift
            if hash.nil?
              nil
            else
              @consumed << hash.dup
              @current_format_state = hash.dup
              @current_format_state.delete(:text)
              hash[:text]
            end
          end

          def preview_next_string
            hash = @unconsumed.first
            if hash.nil? then nil
            else hash[:text]
            end
          end

          def apply_color_and_font_settings(fragment, &block)
            if fragment.color
              original_fill_color = @document.fill_color
              original_stroke_color = @document.stroke_color
              @document.fill_color(*fragment.color)
              @document.stroke_color(*fragment.color)
              apply_font_settings(fragment, &block)
              @document.stroke_color = original_stroke_color
              @document.fill_color = original_fill_color
            else
              apply_font_settings(fragment, &block)
            end
          end

          def apply_font_settings(fragment=nil, &block)
            if fragment.nil?
              font = current_format_state[:font]
              size = current_format_state[:size]
              character_spacing = current_format_state[:character_spacing] ||
                                  @document.character_spacing
              styles = current_format_state[:styles]
              font_style = font_style(styles)
            else
              font = fragment.font
              size = fragment.size
              character_spacing = fragment.character_spacing
              styles = fragment.styles
              font_style = font_style(styles)
            end

            @document.character_spacing(character_spacing) do
              if font || font_style != :normal
                raise "Bad font family" unless @document.font.family
                @document.font(font || @document.font.family, :style => font_style) do
                  apply_font_size(size, styles, &block)
                end
              else
                apply_font_size(size, styles, &block)
              end
            end
          end

          def update_last_string(printed, unprinted, normalized_soft_hyphen)
            return if printed.nil?
            if printed.empty?
              @consumed.pop
            else
              @consumed.last[:text] = printed
              @consumed.last[:normalized_soft_hyphen] = normalized_soft_hyphen
            end

            unless unprinted.empty?
              @unconsumed.unshift(@current_format_state.merge(:text => unprinted))
            end
          end

          def retrieve_fragment
            if @unfinalized_line
              raise "Lines must be finalized before fragments can be retrieved"
            end
            @fragments.shift
          end

          def repack_unretrieved
            new_unconsumed = []
            while fragment = retrieve_fragment
              fragment.include_trailing_white_space!
              new_unconsumed << fragment.format_state.merge(:text => fragment.text)
            end
            @unconsumed = new_unconsumed.concat(@unconsumed)
          end

          def font_style(styles)
            if styles.nil?
              :normal
            elsif styles.include?(:bold) && styles.include?(:italic)
              :bold_italic
            elsif styles.include?(:bold)
              :bold
            elsif styles.include?(:italic)
              :italic
            else
              :normal
            end
          end

          private

          def apply_font_size(size, styles)
            if subscript?(styles) || superscript?(styles)
              relative_size = 0.583
              if size.nil?
                size = @document.font_size * relative_size
              else
                size = size * relative_size
              end
            end
            if size.nil?
              yield
            else
              @document.font_size(size) { yield }
            end
          end

          def subscript?(styles)
            if styles.nil? then false
            else styles.include?(:subscript)
            end
          end

          def superscript?(styles)
            if styles.nil? then false
            else styles.include?(:superscript)
            end
          end

          def omit_trailing_whitespace_from_line_width
            @consumed.reverse_each do |hash|
              if hash[:text] == "\n"
                break
              elsif hash[:text].strip.empty? && @consumed.length > 1
                # this entire fragment is trailing white space
                hash[:exclude_trailing_white_space] = true
              else
                # this fragment contains the first non-white space we have
                # encountered since the end of the line
                hash[:exclude_trailing_white_space] = true
                break
              end
            end
          end

          def set_fragment_measurements(fragment)
            apply_font_settings(fragment) do
              fragment.width = @document.width_of(fragment.text,
                                                  :kerning => @kerning)
              fragment.line_height = @document.font.height
              fragment.descender = @document.font.descender
              fragment.ascender = @document.font.ascender
            end
          end

          def set_line_measurement_maximums(fragment)
            @max_line_height = [@max_line_height, fragment.line_height].max
            @max_descender = [@max_descender, fragment.descender].max
            @max_ascender = [@max_ascender, fragment.ascender].max
          end
          
        end

      end
    end
  end
end
