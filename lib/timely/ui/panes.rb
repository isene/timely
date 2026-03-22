# Pane layout management for Timely
module Timely
  module UI
    module Panes
      TOP_BG = 235
      BOTTOM_BG = 235

      def setup_display
        require 'io/console'
        if IO.console
          @h, @w = IO.console.winsize
        else
          @h = ENV['LINES']&.to_i || 24
          @w = ENV['COLUMNS']&.to_i || 80
        end
      end

      def create_panes
        @panes = {}

        # Top bar
        @panes[:top] = Rcurses::Pane.new(1, 1, @w, 1, 255, TOP_BG)

        # Left pane for calendar view
        left_width = (@w - 4) * @width / 10
        @panes[:left] = Rcurses::Pane.new(2, 3, left_width, @h - 4)

        # Right pane for event details
        @panes[:right] = Rcurses::Pane.new(@panes[:left].w + 4, 3, @w - @panes[:left].w - 4, @h - 4)

        # Bottom bar
        @panes[:bottom] = Rcurses::Pane.new(1, @h, @w, 1, 252, BOTTOM_BG)

        # Initialize scroll positions
        @panes[:left].ix = 0
        @panes[:right].ix = 0

        # Set borders
        set_borders
      end

      def set_borders
        case @border
        when 0
          @panes[:left].border = false
          @panes[:right].border = false
        when 1
          @panes[:left].border = false
          @panes[:right].border = true
        when 2
          @panes[:left].border = true
          @panes[:right].border = true
        when 3
          @panes[:left].border = true
          @panes[:right].border = false
        end
      end

      def render_top_bar
        view_name = case @current_view
                    when :year then "Year"
                    when :quarter then "Quarter"
                    when :month then "Month"
                    when :week then "Week"
                    when :workweek then "Work Week"
                    when :day then "Day"
                    else "Calendar"
                    end

        date_info = case @current_view
                    when :year
                      @selected_date.year.to_s
                    when :quarter
                      q = ((@selected_date.month - 1) / 3) + 1
                      "Q#{q} #{@selected_date.year}"
                    when :month
                      @selected_date.strftime("%B %Y")
                    when :week, :workweek
                      week_start = @selected_date - (@selected_date.cwday - 1)
                      week_end = week_start + 6
                      "#{week_start.strftime('%b %d')} - #{week_end.strftime('%b %d, %Y')}"
                    when :day
                      @selected_date.strftime("%A, %B %d, %Y")
                    else
                      @selected_date.strftime("%B %Y")
                    end

        title = " Timely - ".fg(248) + view_name.b.fg(255) + "  ".fg(245) + date_info.fg(245)
        @panes[:top].text = title
        @panes[:top].refresh
      end

      def render_bottom_bar
        keys = case @current_view
               when :year
                 %w[q:Quit ?:Help 1:Year 3:Month 4:Week 6:Day T:Today g:GoTo]
               when :month
                 %w[q:Quit ?:Help 1:Year 3:Month 4:Week 6:Day T:Today g:GoTo n:New]
               when :week, :workweek
                 %w[q:Quit ?:Help 1:Year 3:Month 4:Week 6:Day T:Today g:GoTo n:New]
               when :day
                 %w[q:Quit ?:Help 1:Year 3:Month 4:Week 6:Day T:Today g:GoTo n:New]
               else
                 %w[q:Quit ?:Help 1-6:Views T:Today g:GoTo]
               end
        @panes[:bottom].text = " " + keys.join(" | ").fg(245)
        @panes[:bottom].refresh
      end
    end
  end
end
