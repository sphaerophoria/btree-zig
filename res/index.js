const cell_width = 50;
const cell_height = 50;
const cell_padding = 10;
const row_padding = 50;
const node_padding = 50;
const half_cell_width = cell_width / 2;
const half_cell_height = cell_height / 2;
const default_cell_color = "#999999";
const delete_cell_color = "#bb0000";
const merge_node_color = "#bbbb00";

/** @param {CanvasRenderingContext2D} ctx */
function renderCell(ctx, num, x, y, color) {
    ctx.fillStyle = color;
    ctx.fillRect(
        x - half_cell_width,
        y - half_cell_height,
        cell_width,
        cell_height,
    );

    ctx.fillStyle = "black";
    ctx.font = "30px Arial";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(num, x, y);

}

function renderNodeBackground(ctx, x_start, x_width, y_center, color) {
    ctx.fillStyle = color;
    const x_with_border = x_width * 1.1;
    const x_center = (x_start + x_start + x_width) / 2.0;
    const y_with_border = cell_height * 1.5;
    ctx.fillRect(
        x_center - x_with_border / 2,
        y_center - y_with_border / 2,
        x_with_border,
        y_with_border,
    );
}

function getElemFromData(elem, data) {
    if (elem.node_type === "leaf") {
        return data.leaf_nodes[elem.index];
    } else if (elem.node_type === "inner") {
        return data.inner_nodes[elem.index];
    } else {
        throw Error("Unexpected node type");
    }
}

function eqlNodeId(a, b) {
    return a.node_type == b.node_type && a.index == b.index;
}

function layoutTreeNode(x, y, elem, data, node_width, layout) {
    const elem_data = getElemFromData(elem, data);
    //if (elem_data.keys.length == 0) {
    //    return y;
    //}
    const start_x = x;
    const layout_node = {
        x: x - half_cell_width,
        y: y,
        val: elem,
    };

    if (data.to_merge) {
        const merge_nodes = [];
        const parent_node = getElemFromData(data.to_merge.parent_node, data);

        merge_nodes.push(parent_node.children[data.to_merge.key_idx]);
        merge_nodes.push(parent_node.children[data.to_merge.key_idx+ 1]);

        console.log("to_merge", merge_nodes);
        console.log("elem", elem);
        for (let merge_elem of merge_nodes) {
            if (eqlNodeId(merge_elem, elem)) {
                layout_node.merge_target = true;
            }
        }
    }
    layout.nodes.push(layout_node);
    for (let i = 0; i < elem_data.keys.length; i++) {
        const cell = elem_data.keys[i];
        const layout_cell = {
            x: x,
            y: y,
            val: cell,
        }
        if (data.to_delete == cell) {
            layout_cell.to_delete = true;
        }

        // FIXME: Gross if block, eql node id on every loop, etc
        if (data.to_merge) {
            if (eqlNodeId(data.to_merge.parent_node, elem)) {
                if (i == data.to_merge.key_idx) {
                    layout_cell.to_merge = true;
                }
            }
        }
        layout.cells.push(layout_cell)

        x += cell_width + cell_padding
    }

    x = start_x + cell_width * 2;
    y += cell_height + row_padding;
    if (elem_data.children === undefined) {
        return y;
    }
    for (let child_elem of elem_data.children) {
        y = layoutTreeNode(x, y, child_elem, data, node_width, layout);
    }
    return y;
}

function renderLayout(ctx, node_width, target, layout) {
    console.log(layout.nodes);
    for (let elem of layout.nodes) {
        let color = undefined;
        console.log(elem);
        switch (elem.val.node_type) {
            case "inner":
                color = "blue";
                break;
            case "leaf":
                color = "purple";
                break;
            default:
                color = "grey";
                break;
        }

        if (elem.merge_target) {
            color = merge_node_color;
        }

        if (target && target.index == elem.val.index && target.node_type == elem.val.node_type) {
            color = "orange";
        }
        renderNodeBackground(ctx, elem.x, node_width, elem.y, color);
    }

    for (let elem of layout.cells) {
        let color = default_cell_color;
        if (elem.to_delete) color = delete_cell_color;
        if (elem.to_merge) color = merge_node_color;
        renderCell(ctx, elem.val, elem.x, elem.y, color);
    }
}

class Page {
    constructor(render_ctx, data) {
        this.ctx = render_ctx;
        this.data = data;
        this.layout = {
            nodes: [],
            cells: [],
        };
        this.dragging = null;
        this.updateLayout();
    }

    nodeWidth() {
        return this.data.node_capacity * cell_width + (this.data.node_capacity - 1) * cell_padding;
    }

    updateLayout() {
        this.layout.cells = []
        this.layout.nodes = []

        if (this.data.to_insert != null) {
            this.layout.cells.push({
                x: 50,
                y: 50,
                val: this.data.to_insert,
            });
        }

        layoutTreeNode(50, 50 + cell_height + row_padding, this.data.root_node, this.data, this.nodeWidth(), this.layout);
        if (this.data.to_insert_child != null) {
            layoutTreeNode(800, 50 + cell_height + row_padding, this.data.to_insert_child, this.data, this.nodeWidth(), this.layout);
        }
    }

    render() {
        this.ctx.fillStyle = "white";
        this.ctx.fillRect(0, 0, this.ctx.canvas.width, this.ctx.canvas.height);

        renderLayout(this.ctx, this.nodeWidth(), this.data.target, this.layout);
    }

    dragStart(x, y) {
        for (let i = 0; i < this.layout.cells.length; i++) {
            const elem = this.layout.cells[i];
            if (x >= elem.x - half_cell_width && x <= elem.x + half_cell_width &&
                y >= elem.y - half_cell_height && y <= elem.y + half_cell_height
            ) {
                this.dragging = i;
                break;
            }
        }

        return null;
    }

    async deleteElem(x, y) {
        // FIXME: Duped with dragStart
        for (let i = 0; i < this.layout.cells.length; i++) {
            const elem = this.layout.cells[i];
            if (x >= elem.x - half_cell_width && x <= elem.x + half_cell_width &&
                y >= elem.y - half_cell_height && y <= elem.y + half_cell_height
            ) {
                await fetch("/delete?val=" + elem.val);
                await this.updateStateAndRerender();
                break;
            }
        }
    }

    onMouseMove(x, y) {
        if (this.dragging === null) {
            return;
        }

        const cell = this.layout.cells[this.dragging];
        cell.x = x;
        cell.y = y;
        this.render();
    }

    dragEnd() {
        this.dragging = null;
    }

    async step() {
        await fetch("/step");
        await this.updateStateAndRerender();
    }

    async reset() {
        await fetch("/reset");
        await this.updateStateAndRerender();
    }

    async updateStateAndRerender() {
        const data_req = await fetch("/data");
        this.data = await data_req.json();
        this.updateLayout();
        this.render();
    }
}

///** @param {CanvasRenderingContext2D} ctx */
//function render(ctx, data) {
//    ctx.fillStyle = "white";
//    ctx.fillRect(0, 0, ctx.canvas.width, ctx.canvas.height);
//
//    if (data.to_insert != null) {
//        renderCell(ctx, data.to_insert, 50, 50);
//    }
//
//    const layout = {
//        nodes: [],
//        cells: [],
//    };
//    const node_width = data.node_capacity * cell_width + (data.node_capacity - 1) * cell_padding;
//    layoutTreeNode(50, 50 + cell_height + row_padding, data.tree, data.data, node_width, layout);
//    renderLayout(ctx, node_width, data.target, layout);
//}

///** @param {CanvasRenderingContext2D} ctx */
//function renderMousePos(ctx, x, y) {
//    ctx.beginPath();
//    ctx.arc(x, y, 10, 0, Math.PI * 2);
//    ctx.fill();
//}

async function init() {
    /** @type HTMLCanvasElement */
    const canvas = document.getElementById("canvas");
    const ctx = canvas.getContext("2d");

    const data_req = await fetch("/data");
    const data = await data_req.json();

    let page = new Page(ctx, data);
    page.render();

    /**@type HTMLButtonElement*/
    const step_button = document.getElementById("step");
    step_button.onclick = () => page.step();

    ///**@type HTMLButtonElement*/
    const reset_button = document.getElementById("reset");
    reset_button.onclick = () => page.reset();

    const reset_layout = document.getElementById("reset_layout");
    reset_layout.onclick = () => {
        page.updateLayout();
        page.render();
    }

    canvas.onmousedown = (ev) => {
        if (ev.button != 0) return;
        page.dragStart(ev.offsetX, ev.offsetY);
    }

    canvas.oncontextmenu = (ev) => {
        page.deleteElem(ev.offsetX, ev.offsetY);
        ev.preventDefault();
    }

    canvas.onmouseup = (ev) => {
        if (ev.button != 0) return;
        page.dragEnd();
    }

    canvas.onmousemove = (ev) => {
        page.onMouseMove(ev.offsetX, ev.offsetY);
    }

    //canvas.onmousemove = (ev) => {
    //    const x = ev.offsetX;
    //    const y = ev.offsetY;
    //    console.log(x, y);
    //    //renderMousePos(ctx, x, y);
    //}

    //render(ctx, data);
}

window.onload = init
