module Timely
  module UI
    module Panes
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

        # Row 1: info bar (1 line)
        # Rows 2..top: month strip (~40% of remaining)
        # Mid section: week view
        # Bottom section: event details
        # Last row: status line (1 line)

        usable = @h - 2  # minus info bar and status line
        top_h = (usable * 0.4).to_i
        top_h = [top_h, 9].max
        bottom_h = (usable * 0.25).to_i
        bottom_h = [bottom_h, 5].max
        mid_h = usable - top_h - bottom_h
        mid_h = [mid_h, 4].max

        # Adjust if total exceeds usable space
        total = top_h + mid_h + bottom_h
        if total > usable
          mid_h = [usable - top_h - bottom_h, 4].max
        end

        @panes[:info] = Rcurses::Pane.new(1, 1, @w, 1, 255, 235)
        @panes[:top] = Rcurses::Pane.new(1, 2, @w, top_h)
        @panes[:mid] = Rcurses::Pane.new(1, 2 + top_h, @w, mid_h)
        @panes[:bottom] = Rcurses::Pane.new(1, 2 + top_h + mid_h, @w, bottom_h)
        @panes[:status] = Rcurses::Pane.new(1, @h, @w, 1, 252, 235)

        @panes.each_value do |p|
          p.border = false
          p.scroll = false
        end
      end
    end
  end
end
