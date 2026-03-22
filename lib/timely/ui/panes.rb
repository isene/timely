# Pane layout management for Timely
# Three horizontal panes stacked vertically
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

        # Top pane: month strip (about 40% of height, at least 10 rows)
        top_h = (@h * 0.4).to_i
        top_h = [top_h, 10].max

        # Bottom pane: event details (about 20% of height, at least 5 rows)
        bottom_h = (@h * 0.2).to_i
        bottom_h = [bottom_h, 5].max

        # Mid pane: gets remaining space (at least 5 rows)
        mid_h = @h - top_h - bottom_h
        mid_h = [mid_h, 5].max

        # Adjust if total exceeds terminal height
        total = top_h + mid_h + bottom_h
        if total > @h
          excess = total - @h
          mid_h = [mid_h - excess, 5].max
        end

        @panes[:top] = Rcurses::Pane.new(1, 1, @w, top_h)
        @panes[:mid] = Rcurses::Pane.new(1, top_h + 1, @w, mid_h)
        @panes[:bottom] = Rcurses::Pane.new(1, top_h + mid_h + 1, @w, bottom_h)

        @panes[:top].border = false
        @panes[:mid].border = false
        @panes[:bottom].border = false

        @panes[:top].scroll = false
        @panes[:mid].scroll = false
        @panes[:bottom].scroll = false
      end
    end
  end
end
