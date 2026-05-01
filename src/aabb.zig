// aabb.zig
const PHYS_EPS = 1e-6;

/// 轴对齐包围盒，用于物理碰撞检测。
pub const AABB = struct {
    min_x: f32,
    min_y: f32,
    min_z: f32,
    max_x: f32,
    max_y: f32,
    max_z: f32,

    pub fn expand(self: AABB, dx: f32, dy: f32, dz: f32) AABB {
        return AABB{
            .min_x = @min(self.min_x, self.min_x + dx),
            .max_x = @max(self.max_x, self.max_x + dx),
            .min_y = @min(self.min_y, self.min_y + dy),
            .max_y = @max(self.max_y, self.max_y + dy),
            .min_z = @min(self.min_z, self.min_z + dz),
            .max_z = @max(self.max_z, self.max_z + dz),
        };
    }

    pub fn move(self: AABB, dx: f32, dy: f32, dz: f32) AABB {
        return AABB{
            .min_x = self.min_x + dx,
            .max_x = self.max_x + dx,
            .min_y = self.min_y + dy,
            .max_y = self.max_y + dy,
            .min_z = self.min_z + dz,
            .max_z = self.max_z + dz,
        };
    }

    pub fn clipXCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        if (moving_box.max_y <= self.min_y or moving_box.min_y >= self.max_y) return move_distance;
        if (moving_box.max_z <= self.min_z or moving_box.min_z >= self.max_z) return move_distance;
        return clipAxisCollide(self.min_x, self.max_x, moving_box.min_x, moving_box.max_x, move_distance);
    }

    pub fn clipYCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        if (moving_box.max_x <= self.min_x or moving_box.min_x >= self.max_x) return move_distance;
        if (moving_box.max_z <= self.min_z or moving_box.min_z >= self.max_z) return move_distance;
        return clipAxisCollide(self.min_y, self.max_y, moving_box.min_y, moving_box.max_y, move_distance);
    }

    pub fn clipZCollide(self: AABB, moving_box: AABB, move_distance: f32) f32 {
        if (moving_box.max_x <= self.min_x or moving_box.min_x >= self.max_x) return move_distance;
        if (moving_box.max_y <= self.min_y or moving_box.min_y >= self.max_y) return move_distance;
        return clipAxisCollide(self.min_z, self.max_z, moving_box.min_z, moving_box.max_z, move_distance);
    }

    fn clipAxisCollide(block_min: f32, block_max: f32, box_min: f32, box_max: f32, move_dist: f32) f32 {
        if (move_dist > 0.0) {
            if (box_max + move_dist > block_min) {
                const max_allowed = block_min - box_max;
                if (max_allowed < 0) {
                    return move_dist;
                }
                return @min(move_dist, max_allowed - PHYS_EPS);
            }
        } else if (move_dist < 0.0) {
            if (box_min + move_dist < block_max) {
                const min_allowed = block_max - box_min;
                if (min_allowed > 0) {
                    return move_dist;
                }
                return @max(move_dist, min_allowed + PHYS_EPS);
            }
        }
        return move_dist;
    }
};
