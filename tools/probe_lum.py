from PIL import Image
import numpy as np
for name in ["docs/probe/views2/20_spawn.png","docs/probe/views2/21_shop.png","docs/probe/views2/22_pier.png"]:
    img = np.asarray(Image.open(name).convert("L"), dtype=np.float32)
    h, w = img.shape
    ground = img[int(h*0.6):, :]
    print(f"{name}: ground mean={ground.mean():.1f}/255  >25: {(ground>25).mean()*100:.1f}%  frame mean={img.mean():.1f}")
