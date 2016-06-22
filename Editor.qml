import QtQuick 2.5
import QtQuick.Window 2.2
import QtMultimedia 5.5
import QtQuick.Controls 2.0
import QtQuick.Controls.Material 2.0
import QtGraphicalEffects 1.0
import QtQuick.LocalStorage 2.0
import "blocks"

Item {
	id: vplEditor

	// whether VPL editor is minimized on top of background image
	property bool minimized: false
	property alias blockEditorVisible: blockEditor.visible
	property alias mainContainerScale: mainContainer.scale

	property alias compiler: compiler
	Compiler {
		id: compiler
	}

	property list<BlockDefinition> eventDefinitions: [
		ButtonsEventBlock {},
		ProxEventBlock {},
		ProxGroundEventBlock {},
		TapEventBlock {},
		ClapEventBlock {},
		TimerEventBlock {}
	]

	property list<BlockDefinition> actionDefinitions: [
		MotorActionBlock {},
		PaletteTopColorActionBlock {},
		PaletteBottomColorActionBlock {},
		TopColorActionBlock {},
		BottomColorActionBlock {}
	]

	readonly property alias blocks: blockContainer.children
	readonly property alias links: linkContainer.children

	readonly property real repulsionMaxDist: 330

	// return a JSON representation of the content of the editor
	function serialize() {
		var out = {};

		// collect blocks and build a map of blocks to id
		var bs = [];
		var btoid = {};
		for (var i = 0; i < blocks.length; ++i) {
			var block = blocks[i];
			var b = block.serialize();
			btoid[block] = i;
			b["id"] = i;
			var blockDefinitionString = block.definition.toString();
			b["definition"] = blockDefinitionString.substr(0, blockDefinitionString.indexOf('_'));
			bs.push(b);
		}
		out["blocks"] = bs;

		// collect links and resolve block references
		var ls = [];
		for (var i = 0; i < links.length; ++i) {
			var link = links[i];
			var l = link.serialize();
			l["source"] = btoid[link.sourceBlock];
			l["dest"] = btoid[link.destBlock];
			ls.push(l);
		}
		out["links"] = ls;

		return out;
	}

	// retrieve the definition of a block from a string
	function getBlockDefinition(definitionString) {
		for (var i = 0; i < eventDefinitions.length; ++i) {
			var blockDefinitionString = eventDefinitions[i].toString();
			if (blockDefinitionString.substr(0, blockDefinitionString.indexOf('_')) === definitionString)
				return eventDefinitions[i];
		}
		for (var i = 0; i < actionDefinitions.length; ++i) {
			var blockDefinitionString = actionDefinitions[i].toString();
			if (blockDefinitionString.substr(0, blockDefinitionString.indexOf('_')) === definitionString)
				return actionDefinitions[i];
		}
		return null;
	}

	// reset content from a JSON representation
	function deserialize(data) {

		// first restore blocks
		blocks = [];
		for (var i = 0; i < data.blocks.length; ++i) {
			var b = data.blocks[i];
			blockComponent.createObject(blockContainer, {
				x: b.x,
				y: b.y,
				definition: getBlockDefinition(b.definition),
				params: b.params,
				isStarting: b.isStarting
			});
		}

		// add then links
		links = [];
		for (var i = 0; i < data.links.length; ++i) {
			var l = data.links[i];
			blockLinkComponent.createObject(linkContainer, {
				sourceBlock: blocks[l.source],
				destBlock: blocks[l.dest],
				isElse: l.isElse
			});
		}

		// then reset view
		mainContainer.fitToView();
	}

	function programsDB() {
		return LocalStorage.openDatabaseSync("Programs", "1.0", "Locally saved programs", 100000);
	}

	function saveProgram(name) {
		programsDB().transaction(
			function(tx) {
				// Create the database if it doesn't already exist
				tx.executeSql('CREATE TABLE IF NOT EXISTS Programs(name TEXT PRIMARY KEY, code TEXT)');
				// Add (another) program
				tx.executeSql('INSERT OR REPLACE INTO Programs VALUES(?, ?)', [ name, JSON.stringify(serialize()) ]);
			}
		)
	}

	function listPrograms() {
		var programs;
		try {
			programsDB().readTransaction(
				function(tx) {
					// List existing programs
					programs = tx.executeSql('SELECT * FROM Programs ORDER BY name').rows;
				}
			)
		}
		catch (err) {
			console.log("list program made an error: ", err);
			programs = [];
		}
		return programs;
	}

	function loadProgram(name) {
		var code;
		try {
			programsDB().readTransaction(
				function(tx) {
					// List existing programs
					code = tx.executeSql('SELECT code FROM Programs WHERE name = ?', name).rows;
				}
			)
		}
		catch (err) {
			console.log("load program made an error: ", err);
			return;
		}
		if (code.length === 0)
			return;
		deserialize(JSON.parse(code[0].code));
	}

	function clearProgram() {
		links = [];
		blocks = [];
		scene.scale = 0.5;
	}

	BlocksPane {
		id: eventPane

		blocks: eventDefinitions
		backImage: "images/eventCenter.svg"

		darkThemeColor: "#301446"
		lightThemeColor: "#ecd2bb"

		anchors.left: parent.left
		anchors.leftMargin: vplEditor.minimized ? -width : 0

		Behavior on anchors.leftMargin { PropertyAnimation {} }
	}

	BlocksPane {
		id: actionPane

		blocks: actionDefinitions
		backImage: "images/actionCenter.svg"

		darkThemeColor: "#301446"
		lightThemeColor: "#b9d6e6"

		anchors.right: parent.right
		anchors.rightMargin: vplEditor.minimized ? -width : 0

		Behavior on anchors.rightMargin { PropertyAnimation {} }
	}

	Rectangle {
		id: mainContainer

		property real foregroundWidth: parent.width - eventPane.width - actionPane.width

		anchors.right: parent.right
		anchors.bottom: parent.bottom
		anchors.rightMargin: vplEditor.minimized ? 0 : actionPane.width

		width: foregroundWidth
		height: parent.height
		//opacity: vplEditor.minimized ? 0.5 : 1.0
		color: vplEditor.minimized ? "#80200032" : "#ff44285a"
		scale: vplEditor.minimized ? 0.5 : 1.0
		transformOrigin: Item.BottomRight

		RadialGradient {
			anchors.fill: parent
			visible: Material.theme === Material.Light
			gradient: Gradient {
				GradientStop { position: 0.0; color: "white" }
				GradientStop { position: 0.5; color: "#eaeced" }
			}
		}

		Behavior on opacity { PropertyAnimation {} }
		Behavior on color { PropertyAnimation {} }
		Behavior on scale { PropertyAnimation {} }
		Behavior on anchors.rightMargin { PropertyAnimation {} }

		// fit all contents to the view
		function fitToView() {
			if (blocks.length === 0)
				return;
			scene.scale = Math.min(width * 0.7 / blockContainer.childrenRect.width, height * 0.7 / blockContainer.childrenRect.height);
			scene.x = width/2 - (blockContainer.childrenRect.x + blockContainer.childrenRect.width/2) * scene.scale;
			scene.y = height/2 - (blockContainer.childrenRect.y + blockContainer.childrenRect.height/2) * scene.scale;
		}

		Image {
			anchors.fill: parent
			source: "images/grid.png"
			fillMode: Image.Tile
			opacity: vplEditor.minimized ? 0 : 1

			Behavior on opacity { PropertyAnimation {} }
		}

		// container for main view
		PinchArea {
			id: pinchArea

			anchors.fill: parent
			clip: true

			property double prevTime: 0

			onPinchStarted: {
				prevTime = new Date().valueOf();
			}

			onPinchUpdated: {
				var deltaScale = pinch.scale - pinch.previousScale

				// adjust content pos due to scale
				if (scene.scale + deltaScale > 1e-1) {
					scene.x += (scene.x - pinch.center.x) * deltaScale / scene.scale;
					scene.y += (scene.y - pinch.center.y) * deltaScale / scene.scale;
					scene.scale += deltaScale;
				}

				// adjust content pos due to drag
				var now = new Date().valueOf();
				var dt = now - prevTime;
				var dx = pinch.center.x - pinch.previousCenter.x;
				var dy = pinch.center.y - pinch.previousCenter.y;
				scene.x += dx;
				scene.y += dy;
				//scene.vx = scene.vx * 0.6 + dx * 0.4 * dt;
				//scene.vy = scene.vy * 0.6 + dy * 0.4 * dt;
				prevTime = now;
			}

			onPinchFinished: {
				//accelerationTimer.running = true;
			}

			MouseArea {
				anchors.fill: parent
				drag.target: scene
				scrollGestureEnabled: false

				onWheel: {
					var deltaScale = scene.scale * wheel.angleDelta.y / 1200.;

					// adjust content pos due to scale
					if (scene.scale + deltaScale > 1e-1) {
						scene.x += (scene.x - mainContainer.width/2) * deltaScale / scene.scale;
						scene.y += (scene.y - mainContainer.height/2) * deltaScale / scene.scale;
						scene.scale += deltaScale;
					}
				}
			}

			Item {
				id: scene

				property int highestZ: 2

				property real vx: 0 // in px per second
				property real vy: 0 // in px per second

				scale: 0.5

				// we use a timer to have some smooth effect
				// TODO: fixme
				Timer {
					id: accelerationTimer
					interval: 17
					repeat: true
					onTriggered: {
						x += (vx * interval) * 0.001;
						y += (vy * interval) * 0.001;
						vx *= 0.85;
						vy *= 0.85;
						if (Math.abs(vx) < 1 && Math.abs(vy) < 1)
						{
							running = false;
							vx = 0;
							vy = 0;
						}
						console.log(vx);
						console.log(vy);
					}
				}

				// methods for querying and modifying block and link graph

				// apply func to every block in the clique starting from block, considering links as undirected
				function applyToClique(block, func, excludedLink) {
					// build block to outgoing links map
					var blockLinks = {};
					for (var i = 0; i < links.length; ++i) {
						var link = links[i];
						if (link === excludedLink)
							continue;
						if (!(link.sourceBlock in blockLinks)) {
							blockLinks[link.sourceBlock] = {};
						}
						// note: we use the same object for key and value in order to access it later
						blockLinks[link.sourceBlock][link.destBlock] = link.destBlock;
						if (!(link.destBlock in blockLinks)) {
							blockLinks[link.destBlock] = {};
						}
						// note: we use the same object for key and value in order to access it later
						blockLinks[link.destBlock][link.sourceBlock] = link.sourceBlock;
					}
					// set of seens blocks
					var seenBlocks = {};
					// recursive function to process each block
					function processBlock(block) {
						if (block in seenBlocks)
							return;
						func(block);
						seenBlocks[block] = true;
						if (!(block in blockLinks))
							return;
						var nextBlocks = blockLinks[block];
						Object.keys(nextBlocks).forEach(function(nextBlockString) {
							var nextBlock = nextBlocks[nextBlockString];
							processBlock(nextBlock);
						});
					}
					// run from the passed block
					processBlock(block);
				}
				function areBlocksInSameClique(block0, block1, excludedLink) {
					var areInSameClique = false;
					applyToClique(block0, function (block) { if (block === block1) { areInSameClique = true; } }, excludedLink);
					return areInSameClique;
				}

				// methods for updating link indicators

				// set starting indicator on either the sourceBlock or the destBlock clique
				function removeLink(link) {
					// if after link is removed the blocks are in the same clique, do not do anything
					if (!areBlocksInSameClique(link.sourceBlock, link.destBlock, link)) {
						// blocks are in different cliques
						var leftHasStart = false;
						applyToClique(link.sourceBlock, function (block) { if (block.isStarting) leftHasStart = true; }, link);
						if (leftHasStart) {
							link.destBlock.isStarting = true;
						} else {
							link.sourceBlock.isStarting = true;
						}
					}
					link.destroy();
				}
				// if the two blocks will form a united clique, clear the start indicator of old destination clique
				function joinClique(sourceBlock, destBlock, excludedLink) {
					var touching = false;
					scene.applyToClique(sourceBlock, function (block) { touching = touching || (block === destBlock); }, excludedLink);
					if (!touching) {
						scene.applyToClique(destBlock, function (block) { block.isStarting = false; }, excludedLink);
					}
				}

				// create a new block at given coordinates
				function createBlock(x, y, definition) {
					var block = blockComponent.createObject(blockContainer, {
						x: x - 128 + Math.random(),
						y: y - 128 + Math.random(),
						definition: definition,
						params: definition.defaultParams
					});
					return block;
				}

				// delete a block and all its links from the scene
				function deleteBlock(block) {
					// yes, collect all links and arrows from/to this block
					var toDelete = []
					for (var i = 0; i < linkContainer.children.length; ++i) {
						var child = linkContainer.children[i];
						// if so, collect for removal
						if (child.sourceBlock === block || child.destBlock === block)
							toDelete.push(child);
					}
					// remove collected links and arrows
					for (i = 0; i < toDelete.length; ++i)
						toDelete[i].destroy();
					// remove this block from the scene
					block.destroy();
				}

				// container for all links
				Item {
					id: linkContainer
					onChildrenChanged: compiler.compile()
				}

				// container for all blocks
				Item {
					id: blockContainer
					onChildrenChanged: compiler.compile()

					// timer to desinterlace objects
					Timer {
						interval: 17
						repeat: true
						running: true

						function sign(v) {
							if (v > 0)
								return 1;
							else if (v < 0)
								return -1;
							else
								return 0;
						}

						onTriggered: {
							var i, j;
							// move all blocks too close
							for (i = 0; i < blocks.length; ++i) {
								for (j = 0; j < i; ++j) {
									var dx = blocks[i].x - blocks[j].x;
									var dy = blocks[i].y - blocks[j].y;
									var dist = Math.sqrt(dx*dx + dy*dy);
									if (dist < repulsionMaxDist) {
										var normDist = dist;
										var factor = 100 / (normDist+1);
										blocks[i].x += sign(dx) * factor;
										blocks[j].x -= sign(dx) * factor;
										blocks[i].y += sign(dy) * factor;
										blocks[j].y -= sign(dy) * factor;
									}
								}
							}
						}
					}
				}

				Component {
					id: blockLinkComponent
					Link { }
				}
			}
		}

		// preview when adding block
		Item {
			id: blockDragPreview
			property BlockDefinition definition: null
			property alias params: loader.defaultParams
			property string backgroundImage
			width: 256
			height: 256
			visible: definition !== null
			scale: scene.scale

			HDPIImage {
				id: centerImageId
				source: blockDragPreview.backgroundImage
				anchors.centerIn: parent
				scale: 0.72
				width: 256 // working around Qt bug with SVG and HiDPI
				height: 256 // working around Qt bug with SVG and HiDPI
			}

			Loader {
				id: loader
				property var defaultParams
				anchors.centerIn: parent
				sourceComponent: blockDragPreview.definition ? blockDragPreview.definition.miniature : null
				scale: 0.72
			}
		}

		Component {
			id: blockComponent
			Block {
			}
		}

		// center view
		Item {
			width: 48
			height: 48
			anchors.right: parent.right
			anchors.rightMargin: 4
			anchors.bottom: parent.bottom
			anchors.bottomMargin: 4

			HDPIImage {
				source: Material.theme === Material.Light ? "icons/ic_gps_fixed_black_24px.svg" : "icons/ic_gps_fixed_white_24px.svg"
				width: 24 // working around Qt bug with SVG and HiDPI
				height: 24 // working around Qt bug with SVG and HiDPI
				anchors.centerIn: parent
				visible: !minimized
			}

			MouseArea {
				anchors.fill: parent
				onClicked: mainContainer.fitToView();
			}
		}

		// block editor
		BlockEditor {
			id: blockEditor
		}
	}
}
